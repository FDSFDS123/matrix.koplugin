use axum::{
    extract::{Query, State,RawQuery},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use matrix_sdk::{
    config::SyncSettings,
    encryption::verification::SasVerification,
    ruma::{
        events::{
            key::verification::request::ToDeviceKeyVerificationRequestEventContent,
            room::message::OriginalSyncRoomMessageEvent,
            ToDeviceEvent,
        },
        OwnedUserId,
    },
    Client, Room,
};
use matrix_sdk::{
    authentication::matrix::MatrixSession,
};
use ruma::{
    events::room::message::{RoomMessageEventContent},
    RoomId, RoomOrAliasId,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use std::time::Duration;
use tokio::fs;
use tokio::time::sleep;
use tracing::{error, info};

const SESSION_FILE: &str = "session.json";

// ==========================================
// STATE & DATA STRUCTURES
// ==========================================

#[derive(Deserialize)]
struct TokenLoginRequest {
    user_id: String,
    access_token: String,
}

#[derive(Clone, Serialize, Deserialize, Debug)]
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
    room_id: String,
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct SsoCallbackQuery {
    #[serde(alias = "%?loginToken", alias = "loginToken", rename = "loginToken")]
    login_token: Option<String>,
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

    let homeserver_url = "https://mozilla.modular.im";
    let data_dir = "./matrix-data";

    info!("Initializing Matrix Client with SQLite storage at {}", data_dir);

    let client = Client::builder()
        .homeserver_url(homeserver_url)
        .sqlite_store(data_dir, None)
        .build()
        .await?;

    // In-memory message store (messages are lost on restart)
    let message_store = Arc::new(Mutex::new(Vec::new()));

    let state = AppState {
        client: client.clone(),
        message_store: message_store.clone(),
    };

    // Restore saved session if available (Login Credentials Persistence)
    if let Ok(saved) = fs::read_to_string(SESSION_FILE).await {
        match serde_json::from_str::<MatrixSession>(&saved) {
            Ok(sess) => {
                if let Err(e) = client.restore_session(sess).await {
                    error!("Failed to restore session from disk: {:?}", e);
                } else {
                    info!("Restored session from disk");
                }
            }
            Err(_) => {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&saved) {
                    if let Some(token) = val.get("access_token").and_then(|v| v.as_str()) {
                        info!("Found access_token in saved session.json; attempting token login");
                        if let Err(e) = client.matrix_auth().login_token(token).send().await {
                            error!("Failed token login from saved session.json: {:?}", e);
                        } else {
                            info!("Logged in via token from saved session.json");
                        }
                    }
                }
            }
        }
    }

    if client.user_id().is_some() {
        info!("Found existing session. Starting background sync...");
        start_sync_loop(client.clone(), message_store);
    } else {
        info!("No session found. Please authenticate via login/SSO endpoint.");
    }

    let app = Router::new()
        .route("/health", get(health_check_handler))
        .route("/auth/sso/url", get(sso_url_handler))
        .route("/auth/sso/callback", get(sso_callback_handler))
        .route("/auth/login", post(login_handler))
        .route("/auth/token", post(token_login_handler))
        .route("/send", post(send_message_handler))
        .route("/messages", get(get_messages_handler))
        .route("/rooms", get(list_rooms_handler))
        .route("/rooms/all", get(list_all_rooms_handler))
        .route("/rooms/join", post(join_room_handler))
        .route("/rooms/leave", post(leave_room_handler))
        .route("/invites", get(list_invites_handler))
        .route("/auth/verify", get(verify_handler))
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    info!("Daemon listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

// ==========================================
// BACKGROUND SYNC
// ==========================================
fn start_sync_loop(client: Client, message_store: Arc<Mutex<Vec<ReceivedMessage>>>) {
    // 1. Event handler for incoming room messages
    client.add_event_handler(move |event: OriginalSyncRoomMessageEvent, room: Room| {
        let store = message_store.clone();
        async move {
            let msg = ReceivedMessage {
                sender: event.sender.to_string(),
                room_id: room.room_id().to_string(),
                body: event.content.body().to_string(),
                timestamp_ms: u64::from(event.origin_server_ts.get()),
            };

            let mut store_lock = store.lock().unwrap();
            store_lock.push(msg);
            if store_lock.len() > 100 {
                store_lock.remove(0);
            }
        }
    });

    // 2. Event handler for ToDevice key verification requests
    client.add_event_handler(
        |event: ToDeviceEvent<ToDeviceKeyVerificationRequestEventContent>, client: Client| async move {
            let sender = event.sender.clone();
            let transaction_id = event.content.transaction_id.to_string();

            info!(
                "Received key verification request from sender: {} (transaction_id: {})",
                sender, transaction_id
            );

            let encryption = client.encryption();

            // Wait for and accept the initial verification request
            let mut request_accepted = false;
            for _ in 0..10 {
                sleep(Duration::from_millis(500)).await;

                if let Some(req) = encryption
                    .get_verification_request(&sender, &transaction_id)
                    .await
                {
                    info!("Found verification request, accepting...");
                    if let Err(e) = req.accept().await {
                        error!("Failed to accept verification request: {:?}", e);
                        return;
                    }
                    request_accepted = true;
                    break;
                }
            }

            if !request_accepted {
                error!("Timed out waiting to find verification request.");
                return;
            }

            // Spawn background handler task so /sync loop can process E2EE messages
            tokio::spawn(handle_sas_flow(client, sender, transaction_id));
        },
    );

    // 3. Spawn thread to handle background sync process
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime.block_on(async move {
            // Fast initial sync pass
            let initial_settings = SyncSettings::default().timeout(Duration::from_secs(0));
            match client.sync_once(initial_settings).await {
                Ok(_) => {
                    info!(
                        "Initial sync complete! Store populated with {} joined room(s).",
                        client.joined_rooms().len()
                    );
                }
                Err(e) => {
                    error!("Initial sync_once failed: {:?}", e);
                }
            }

            // Continuous background sync loop
            let settings = SyncSettings::default();
            if let Err(e) = client.sync(settings).await {
                error!("Background sync loop stopped: {:?}", e);
            }
        });
    });
}

pub fn setup_verification_handler(client: &Client) {
    let client_clone = client.clone();

    // Listen for incoming verification requests
    client.add_event_handler(
        move |event: ToDeviceEvent<ToDeviceKeyVerificationRequestEventContent>| {
            let client = client_clone.clone();
            async move {
                let sender = &event.sender;
                let flow_id = &event.content.transaction_id;

                println!("Received verification request from {}", sender);

                // 1. Retrieve the request object
                if let Some(req) = client.encryption().get_verification_request(sender, flow_id).await {
                    // 2. Accept the verification request (sends 'm.key.verification.ready')
                    if let Err(e) = req.accept().await {
                        eprintln!("Failed to accept verification request: {e}");
                        return;
                    }
                    println!("Accepted verification request. Waiting for SAS start...");

                    // 3. Spawn a background task to handle the SAS exchange
                    tokio::spawn(handle_sas_flow(client, sender.clone(), flow_id.to_string()));
                }
            }
        },
    );
}
async fn handle_sas_flow(client: Client, sender: OwnedUserId, flow_id: String) {
    let mut sas: Option<SasVerification> = None;

    // Poll for the SAS object to become ready
    for _ in 0..30 {
        sleep(Duration::from_millis(500)).await;

        if let Some(verification) = client.encryption().get_verification(&sender, &flow_id).await {
            if let Some(s) = verification.sas() {
                sas = Some(s);
                break;
            }
        }
    }

    let Some(sas) = sas else {
        error!("Timed out waiting for SAS process to initiate.");
        return;
    };

    // Accept the SAS protocol start
    info!("Accepting SAS verification...");
    if let Err(e) = sas.accept().await {
        error!("Failed to accept SAS: {:?}", e);
        return;
    }

    // Poll for key exchange completion
    for _ in 0..30 {
        sleep(Duration::from_millis(500)).await;

        if sas.is_done() {
            info!("SAS Verification completed successfully!");
            return;
        }

        if sas.is_cancelled() {
            error!("SAS Verification was cancelled.");
            return;
        }

        if let Some(emojis) = sas.emoji() {
            let emoji_str: Vec<String> = emojis
                .iter()
                .map(|e| format!("{} ({})", e.symbol, e.description))
                .collect();

            info!("================================================");
            info!("SAS VERIFICATION EMOJIS MATCH CHECK:");
            info!("{}", emoji_str.join("  |  "));
            info!("================================================");

            if let Err(e) = sas.confirm().await {
                error!("Failed to confirm SAS verification: {:?}", e);
            } else {
                info!("SAS verification confirmed successfully!");
            }
            break;
        }
    }
}
async fn health_check_handler() -> Result<Json<StatusResponse>, StatusCode> {
    Ok(Json(StatusResponse { status: "ok".to_string() }))
}

async fn list_all_rooms_handler(State(state): State<AppState>) -> Result<Json<Vec<RoomDetails>>, StatusCode> {
    if !state.client.user_id().is_none() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let room_list = state
        .client
        .joined_rooms()
        .into_iter()
        .map(|r| RoomDetails {
            room_id: r.room_id().to_string(),
            name: r.name(),
        })
        .collect();
    Ok(Json(room_list))
}

async fn sso_url_handler(State(state): State<AppState>) -> Result<String, StatusCode> {
    // 1. Ensure absolute string with NO trailing spaces or slashes
    let callback_url = "http://127.0.0.1:8080/auth/sso/callback".trim();

    // 2. Call matrix-sdk SSO URL builder
    let sso_url = state
        .client
        .matrix_auth()
        .get_sso_login_url(callback_url, None)
        .await
        .map_err(|e| {
            error!("Failed to generate SSO URL: {:?}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    Ok(sso_url)
}
async fn token_login_handler(
    State(state): State<AppState>,
    Json(payload): Json<TokenLoginRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    info!("Attempting login via access token for user: {}", payload.user_id);
    match state.client.matrix_auth().login_token(&payload.access_token).send().await {
        Ok(_) => {
            if let Some(session) = state.client.matrix_auth().session() {
                let _ = fs::write(SESSION_FILE, serde_json::to_string(&session).unwrap()).await;
            }
            start_sync_loop(state.client.clone(), state.message_store.clone());
            Ok(Json(StatusResponse { status: "logged_in".to_string() }))
        }
        Err(e) => {
            error!("Failed to authenticate via token: {:?}", e);
            Err(StatusCode::FORBIDDEN)
        }
    }
}

async fn login_handler(
    State(state): State<AppState>,
    Json(payload): Json<LoginRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    info!("Attempting password login for user: {}", payload.username);
    match state
        .client
        .matrix_auth()
        .login_username(&payload.username, &payload.password)
        .initial_device_display_name("axum-daemon")
        .send()
        .await
    {
        Ok(_) => {
            if let Some(session) = state.client.matrix_auth().session() {
                let _ = fs::write(SESSION_FILE, serde_json::to_string(&session).unwrap()).await;
            }
            start_sync_loop(state.client.clone(), state.message_store.clone());
            Ok(Json(StatusResponse { status: "logged_in".to_string() }))
        }
        Err(e) => {
            error!("Login failed: {:?}", e);
            Err(StatusCode::FORBIDDEN)
        }
    }
}

async fn list_invites_handler(State(state): State<AppState>) -> Result<Json<Vec<InviteDetails>>, StatusCode> {
    if !state.client.user_id().is_none() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let invite_list = state
        .client
        .invited_rooms()
        .into_iter()
        .map(|r| InviteDetails {
            room_id: r.room_id().to_string(),
            name: r.name(),
        })
        .collect();
    Ok(Json(invite_list))
}
async fn verify_handler(
    State(state): State<AppState>,
) -> Result<Json<Value>, StatusCode> {
    if state.client.user_id().is_none() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    match state.client.whoami().await {
        Ok(res) => Ok(Json(json!({
            "status": "valid",
            "user_id": res.user_id.to_string(),
            "device_id": res.device_id.map(|d| d.to_string()),
        }))),
        Err(e) => {
            error!("Session verification failed: {:?}", e);
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}
async fn sso_callback_handler(
    State(state): State<AppState>,
    Query(query): Query<SsoCallbackQuery>,
    RawQuery(raw_query): RawQuery,
) -> Result<&'static str, StatusCode> {
    // Extract token either from Serde struct or by cleaning raw query manually
    let token = query.login_token.or_else(|| {
        raw_query.and_then(|q| {
            q.split("loginToken=")
                .nth(1)
                .map(|t| t.trim_start_matches('%').to_string())
        })
    });

    let login_token = match token {
        Some(t) if !t.is_empty() => t,
        _ => {
            error!("Missing or malformed loginToken in SSO callback");
            return Err(StatusCode::BAD_REQUEST);
        }
    };

    match state.client.matrix_auth().login_token(&login_token).send().await {
        Ok(_) => {
            if let Some(session) = state.client.matrix_auth().session() {
                let _ = fs::write(SESSION_FILE, serde_json::to_string(&session).unwrap()).await;
            }
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
    if !state.client.user_id().is_none() {
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
async fn list_rooms_handler(
    State(state): State<AppState>,
) -> Result<Json<Vec<RoomDetails>>, (StatusCode, &'static str)> {
    // Check if client is authenticated
    if state.client.user_id().is_none() {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Client is not authenticated. Please log in first.",
        ));
    }

    // Retrieve joined rooms from local storage
    let joined = state.client.joined_rooms();

    let room_list: Vec<RoomDetails> = joined
        .into_iter()
        .map(|r| RoomDetails {
            room_id: r.room_id().to_string(),
            name: r.name(),
        })
        .collect();

    Ok(Json(room_list))
}

async fn join_room_handler(
    State(state): State<AppState>,
    Json(payload): Json<RoomActionRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    if !state.client.user_id().is_none() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let room_id_or_alias = RoomOrAliasId::parse(&payload.room_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    match state.client.join_room_by_id_or_alias(&room_id_or_alias, &[]).await {
        Ok(_) => Ok(Json(StatusResponse { status: "joined".to_string() })),
        Err(e) => {
            error!("Failed to join room: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn leave_room_handler(
    State(state): State<AppState>,
    Json(payload): Json<RoomActionRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    if !state.client.user_id().is_none() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let room_id = RoomId::parse(&payload.room_id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let room = state.client.get_room(&room_id).ok_or(StatusCode::NOT_FOUND)?;
    match room.leave().await {
        Ok(_) => Ok(Json(StatusResponse { status: "left".to_string() })),
        Err(e) => {
            error!("Failed to leave room: {:?}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}
