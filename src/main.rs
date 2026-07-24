// Basic matrix-helper scaffold using matrix-rust-sdk (0.7 series).
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
