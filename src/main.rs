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

#[derive(Deserialize)]
struct TokenLoginRequest {
    // user_id can be kept or ignored since login_token extracts session data automatically from the homeserver via the token
    user_id: String,
    access_token: String,
}
#[derive(Clone, Serialize)]
struct ReceivedMessage {
    sender: String,
    room_id: String,
    body: String,
    timestamp_ms: u64,
}
#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
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
#[derive(Clone, Serialize)]
struct InviteDetails {
    room_id: String,
    name: Option<String>,
}

// ==========================================
// MAIN DAEMON SETUP
// ==========================================

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let homeserver_url = "https://mozilla.modular.im"; // Replace with your homeserver if different
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
        .route("/health", get(health_check_handler))
        .route("/auth/sso/callback", get(sso_callback_handler))
        .route("/send", post(send_message_handler))
        .route("/messages", get(get_messages_handler))
        .route("/auth/token", post(token_login_handler))
        .route("/rooms", get(list_rooms_handler))
        .route("/rooms/join", post(join_room_handler))
        .route("/rooms/leave", post(leave_room_handler))
        .route("/auth/login", post(login_handler))
        .route("/invites", get(list_invites_handler))
        .route("/rooms/all", get(list_all_rooms_handler))
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    info!("Daemon listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
/// GET /rooms/all - List all joined rooms with names for bulk syncing
async fn list_all_rooms_handler(State(state): State<AppState>) -> Result<Json<Vec<RoomDetails>>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let joined_rooms = state.client.joined_rooms();
    let mut room_list = Vec::new();

    for room in joined_rooms {
        room_list.push(RoomDetails {
            room_id: room.room_id().to_string(),
            name: room.name(),
        });
    }

    Ok(Json(room_list))
}
/// GET /auth/sso/url - Generate the SSO login URL for the homeserver
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
async fn token_login_handler(
    State(state): State<AppState>,
    Json(payload): Json<TokenLoginRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    info!("Attempting login via access token for user: {}", payload.user_id);

    // Use matrix-sdk's token login builder correctly with .send().await
    match state.client.matrix_auth().login_token(&payload.access_token).send().await {
        Ok(_) => {
            info!("Session successfully authenticated via token! Starting background sync.");
            start_sync_loop(state.client.clone(), state.message_store.clone());
            Ok(Json(StatusResponse { status: "logged_in".to_string() }))
        }
        Err(e) => {
            error!("Failed to authenticate via token: {:?}", e);
            Err(StatusCode::FORBIDDEN)
        }
    }
}
/// POST /auth/login - Standard Username & Password login
async fn login_handler(
    State(state): State<AppState>,
    Json(payload): Json<LoginRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    info!("Attempting password login for user: {}", payload.username);
    
    match state.client.matrix_auth().login_username(&payload.username, &payload.password).await {
        Ok(_) => {
            info!("Password login successful! Starting background sync.");
            start_sync_loop(state.client.clone(), state.message_store.clone());
            Ok(Json(StatusResponse { status: "logged_in".to_string() }))
        }
        Err(e) => {
            error!("Login failed: {:?}", e);
            Err(StatusCode::FORBIDDEN)
        }
    }
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
/// GET /health - Check if daemon is active
async fn health_check_handler() -> Result<Json<StatusResponse>, StatusCode> {
    Ok(Json(StatusResponse { status: "ok".to_string() }))
}

/// GET /invites - List pending room invitations
async fn list_invites_handler(State(state): State<AppState>) -> Result<Json<Vec<InviteDetails>>, StatusCode> {
    if !state.client.logged_in() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let invited_rooms = state.client.invited_rooms();
    let mut invite_list = Vec::new();

    for room in invited_rooms {
        invite_list.push(InviteDetails {
            room_id: room.room_id().to_string(),
            name: room.name(),
        });
    }

    Ok(Json(invite_list))
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
}
