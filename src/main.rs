use axum::{
    extract::{Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use matrix_sdk::{config::SyncSettings, Client, Room};
use ruma::{
    events::room::message::{OriginalSyncRoomMessageEvent, RoomMessageEventContent},
    RoomId, RoomOrAliasId,
};
use serde::{Deserialize, Serialize};
use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use tracing::{error, info};
// ==========================================
// STATE & DATA STRUCTURES
// ==========================================

#[derive(Clone, Serialize)]
struct ReceivedMessage {
    sender: String,
    room_id: String,
    body: String,
    timestamp_ms: u64,
}

#[derive(Clone)]
struct AppState {
    client: Client,
    message_store: Arc<Mutex<Vec<ReceivedMessage>>>,
}

#[derive(Deserialize)]
struct SendMessageRequest {
    room_id: String,
    message: String,
}

#[derive(Deserialize)]
struct RoomActionRequest {
    room_id: String, // Can be a Room ID (!xyz:matrix.org) or Alias (#xyz:matrix.org) for joining
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct SsoCallbackQuery {
    loginToken: String,
}

#[derive(Serialize)]
struct StatusResponse {
    status: String,
}

#[derive(Serialize)]
struct RoomDetails {
    room_id: String,
    name: Option<String>,
}

// ==========================================
// MAIN DAEMON SETUP
// ==========================================

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let homeserver_url = "https://matrix.org"; // Replace with your homeserver if different
    let data_dir = "./matrix-data";

    info!("Initializing Matrix Client with SQLite storage at {}", data_dir);

    let client = Client::builder()
        .homeserver_url(homeserver_url)
        .sqlite_store(data_dir, None)
        .build()
        .await?;

    let message_store = Arc::new(Mutex::new(Vec::new()));

    let state = AppState {
        client: client.clone(),
        message_store: message_store.clone(),
    };

    if client.logged_in() {
        info!("Found existing session. Starting background sync for E2EE...");
        start_sync_loop(client.clone(), message_store);
    } else {
        info!("No session found. Please authenticate via SSO endpoint.");
    }

    let app = Router::new()
        .route("/auth/sso/url", get(sso_url_handler))
        .route("/auth/sso/callback", get(sso_callback_handler))
        .route("/send", post(send_message_handler))
        .route("/messages", get(get_messages_handler))
        .route("/rooms", get(list_rooms_handler))
        .route("/rooms/join", post(join_room_handler))
        .route("/rooms/leave", post(leave_room_handler))
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    info!("Daemon listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
fn start_sync_loop(client: Client, message_store: Arc<Mutex<Vec<ReceivedMessage>>>) {
    // Note the addition of `room: Room` in the closure arguments
    client.add_event_handler(move |event: OriginalSyncRoomMessageEvent, room: Room| {
        let store = message_store.clone();
        async move {
            let msg = ReceivedMessage {
                sender: event.sender.to_string(),
                // We extract the room_id from the Room context, not the event payload
                room_id: room.room_id().to_string(),
                body: event.content.body().to_string(),
                // Call .get() to unwrap the Ruma timestamp type before converting to u64
                timestamp_ms: u64::from(event.origin_server_ts.get()),
            };

            let mut store_lock = store.lock().unwrap();
            store_lock.push(msg);
            if store_lock.len() > 50 {
                store_lock.remove(0); // Keep memory footprint small
            }
        }
    });

    tokio::spawn(async move {
        let settings = SyncSettings::default();
        if let Err(e) = client.sync(settings).await {
            error!("Background sync failed: {:?}", e);
        }
    });
}
// ==========================================
// HTTP HANDLERS
// ==========================================

async fn sso_url_handler(State(state): State<AppState>) -> Result<String, StatusCode> {
    let callback_url = "http://127.0.0.1:8080/auth/sso/callback";
    match state.client.matrix_auth().get_sso_login_url(callback_url, None).await {
        Ok(url) => Ok(url),
        Err(e) => {
            error!("Failed to generate SSO URL: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn sso_callback_handler(
    State(state): State<AppState>,
    Query(query): Query<SsoCallbackQuery>,
) -> Result<&'static str, StatusCode> {
    info!("Received SSO callback. Completing login...");
    match state.client.matrix_auth().login_token(&query.loginToken).await {
        Ok(_) => {
            info!("Login successful! Starting background sync.");
            start_sync_loop(state.client.clone(), state.message_store.clone());
            Ok("Login successful. You can close this window.")
        }
        Err(e) => {
            error!("SSO Login failed: {:?}", e);
            Err(StatusCode::FORBIDDEN)
        }
    }
}

async fn get_messages_handler(State(state): State<AppState>) -> Json<Vec<ReceivedMessage>> {
    let store = state.message_store.lock().unwrap();
    Json(store.clone())
}

async fn send_message_handler(
    State(state): State<AppState>,
    Json(payload): Json<SendMessageRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let room_id = RoomId::parse(&payload.room_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let room = state.client.get_room(&room_id).ok_or(StatusCode::NOT_FOUND)?;
    let content = RoomMessageEventContent::text_plain(&payload.message);

    match room.send(content).await {
        Ok(_) => Ok(Json(StatusResponse { status: "sent".to_string() })),
        Err(e) => {
            error!("Failed to send message: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// GET /rooms - List joined rooms
async fn list_rooms_handler(State(state): State<AppState>) -> Result<Json<Vec<RoomDetails>>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let joined_rooms = state.client.joined_rooms();
    let mut room_list = Vec::new();

    for room in joined_rooms {
        room_list.push(RoomDetails {
            room_id: room.room_id().to_string(),
            name: room.name(), // Returns Option<String>
        });
    }

    Ok(Json(room_list))
}

/// POST /rooms/join - Join a room by ID or Alias
async fn join_room_handler(
    State(state): State<AppState>,
    Json(payload): Json<RoomActionRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let room_id_or_alias = RoomOrAliasId::parse(&payload.room_id).map_err(|_| StatusCode::BAD_REQUEST)?;

    match state.client.join_room_by_id_or_alias(&room_id_or_alias, &[]).await {
        Ok(_) => {
            info!("Successfully joined room: {}", payload.room_id);
            Ok(Json(StatusResponse { status: "joined".to_string() }))
        }
        Err(e) => {
            error!("Failed to join room: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /rooms/leave - Leave a room
async fn leave_room_handler(
    State(state): State<AppState>,
    Json(payload): Json<RoomActionRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let room_id = RoomId::parse(&payload.room_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let room = state.client.get_room(&room_id).ok_or(StatusCode::NOT_FOUND)?;

    match room.leave().await {
        Ok(_) => {
            info!("Successfully left room: {}", payload.room_id);
            Ok(Json(StatusResponse { status: "left".to_string() }))
        }
        Err(e) => {
            error!("Failed to leave room: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}// Basic matrix-helper scaffold using matrix-rust-sdk (0.7 series).
// Note: You may need to adapt small APIs to match the exact SDK version you build with.

use std::{collections::{HashMap, VecDeque}, net::SocketAddr, sync::Arc};

use anyhow::Result;
use axum::{
    extract::{Json, Path, State},
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tracing::info;

use matrix_sdk::{
    config::SyncSettings,
    ruma::{events::room::message::RoomMessageEventContent, RoomId},
    Client,
};

#[derive(Clone)]
struct AppState {
    client: Arc<Mutex<Option<Client>>>,
    room_buffers: Arc<Mutex<HashMap<String, VecDeque<SimpleMessage>>>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct SimpleMessage {
    event_id: String,
    room_id: String,
    sender: String,
    body: String,
    formatted: Option<String>,
    timestamp_millis: i64,
}

#[derive(Deserialize)]
struct LoginRequest {
    homeserver: String,
    username: Option<String>,
    password: Option<String>,
    access_token: Option<String>,
}

#[derive(Deserialize)]
struct SendRequest {
    room_id: String,
    body: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let state = AppState {
        client: Arc::new(Mutex::new(None)),
        room_buffers: Arc::new(Mutex::new(HashMap::new())),
    };

    let app = Router::new()
        .route("/login", post(login_handler))
        .route("/send", post(send_handler))
        .route("/rooms/:room_id/messages", get(fetch_messages_handler))
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], 3030));
    info!("matrix-helper listening on {}", addr);
    axum::Server::bind(&addr).serve(app.into_make_service()).await?;
    Ok(())
}

async fn login_handler(State(state): State<AppState>, Json(body): Json<LoginRequest>) -> Json<serde_json::Value> {
    if body.access_token.is_none() && (body.username.is_none() || body.password.is_none()) {
        return Json(serde_json::json!({"error": "Provide access_token or username+password"}));
    }

    let homeserver = body.homeserver.clone();

    // Build client with persistent sled store (sled_cryptostore feature required)
    let client_builder = Client::builder().homeserver_url(homeserver.clone());
    let client = match client_builder.build().await {
        Ok(c) => c,
        Err(e) => return Json(serde_json::json!({"error": format!("client build failed: {}", e)})),
    };

    // Login: prefer username+password; token restoration path may need SDK-specific API.
    if let Some(token) = &body.access_token {
        // Many SDK versions provide session restore functionality; if not available, replace with login or session creation.
        if let Err(e) = client.restore_login(token).await {
            return Json(serde_json::json!({"error": format!("failed to restore token: {}", e)}));
        }
    } else if let (Some(user), Some(pass)) = (&body.username, &body.password) {
        match client.login_username(user, pass).send().await {
            Ok(_) => (),
            Err(e) => return Json(serde_json::json!({"error": format!("login failed: {}", e)})),
        }
    }

    // Register handler to capture (decrypted) messages
    {
        let buffers = state.room_buffers.clone();
        client.register_event_handler(move |ev: matrix_sdk::ruma::events::room::message::SyncRoomMessageEvent, room: matrix_sdk::room::Room| {
            let buffers = buffers.clone();
            async move {
                if let matrix_sdk::ruma::events::room::message::MessageType::Text(text) = &ev.content.msgtype {
                    let msg = SimpleMessage {
                        event_id: ev.event_id.to_string(),
                        room_id: room.room_id().to_string(),
                        sender: ev.sender.to_string(),
                        body: text.body.clone(),
                        formatted: text.formatted.as_ref().map(|f| f.body.clone()),
                        timestamp_millis: ev.origin_server_ts.into(),
                    };
                    let mut map = buffers.lock().await;
                    let q = map.entry(room.room_id().to_string()).or_insert_with(|| VecDeque::with_capacity(200));
                    q.push_front(msg);
                    while q.len() > 200 { q.pop_back(); }
                }
            }
        }).await;
    }

    // Start background sync (keeps encryption keys and room keys up to date)
    {
        let client_clone = client.clone();
        tokio::spawn(async move {
            let sync_settings = SyncSettings::default();
            if let Err(e) = client_clone.sync_forever(sync_settings, |_| async {}).await {
                tracing::error!("sync_forever error: {:?}", e);
            }
        });
    }

    // store the client
    {
        let mut guard = state.client.lock().await;
        *guard = Some(client);
    }

    Json(serde_json::json!({"ok": true}))
}

async fn send_handler(State(state): State<AppState>, Json(req): Json<SendRequest>) -> Json<serde_json::Value> {
    let guard = state.client.lock().await;
    let client = match &*guard {
        Some(c) => c.clone(),
        None => return Json(serde_json::json!({"error": "not logged in"})),
    };

    // parse room id
    let room_id = match RoomId::parse(req.room_id.clone()) {
        Ok(rid) => rid,
        Err(_) => return Json(serde_json::json!({"error": "invalid room_id"})),
    };

    match client.get_joined_room(&room_id) {
        Some(room) => {
            let content = RoomMessageEventContent::text_plain(req.body.clone());
            if let Err(e) = room.send(content, None).await {
                return Json(serde_json::json!({"error": format!("send failed: {}", e)}));
            }
            Json(serde_json::json!({"ok": true}))
        }
        None => Json(serde_json::json!({"error": "not joined to room"})),
    }
}

async fn fetch_messages_handler(State(state): State<AppState>, Path(room_id): Path<String>) -> Json<serde_json::Value> {
    let map = state.room_buffers.lock().await;
    if let Some(buf) = map.get(&room_id) {
        let items: Vec<SimpleMessage> = buf.iter().cloned().take(50).collect();
        Json(serde_json::json!({"messages": items}))
    } else {
        Json(serde_json::json!({"messages": []}))
    }
}
