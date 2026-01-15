use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

mod types;
use tokio::net::tcp::OwnedWriteHalf;
use types::*;

struct AppState {
    clients: HashMap<String, OwnedWriteHalf>,
    users: HashMap<String, UserInfo>,
    files: HashMap<String, Vec<String>>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            clients: HashMap::new(),
            users: HashMap::new(),
            files: HashMap::new(),
        }
    }
}

type SharedAppState = Arc<Mutex<AppState>>;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:8080").await?;
    println!("Server listening on localhost:8080");

    let app_state: SharedAppState = Arc::new(Mutex::new(AppState::new()));

    loop {
        let (mut socket, addr) = listener.accept().await?;
        println!("New connection from: {}", addr);

        let app_state = app_state.clone();

        tokio::spawn(async move {
            let (mut reader, mut writer) = socket.into_split();

            let mut client_id: Option<String> = None;
            let mut socket_writer = Some(writer);

            let mut buf_reader = BufReader::new(reader);

            let mut line = String::new();
            loop {
                line.clear();
                let bytes_read = match buf_reader.read_line(&mut line).await {
                    Ok(0) => {
                        println!("Client disconnected: {:?}", client_id);
                        break;
                    }
                    Ok(n) => n,
                    Err(e) => {
                        eprintln!("Error reading from socket: {}", e);
                        break;
                    }
                };

                if line.trim().is_empty() {
                    continue;
                }

                println!("Received: {}", line.trim());

                match serde_json::from_str::<WebSocketMessage>(&line) {
                    Ok(msg) => {
                        if client_id.is_none() {
                            client_id = Some(msg.client_id.clone());
                        }
                        handle_message(msg, app_state.clone(), &mut socket_writer).await;
                    }
                    Err(e) => {
                        eprintln!("Error parsing message: {}", e);
                    }
                }
            }

            if let Some(id) = client_id {
                println!("Cleaning up client: {}", id);
                let mut state = app_state.lock().await;
                state.clients.remove(&id);
                state.users.remove(&id);
            }
        });
    }
}

async fn handle_message(
    msg: WebSocketMessage,
    app_state: SharedAppState,
    socket_writer: &mut Option<OwnedWriteHalf>,
) {
    let mut guard = app_state.lock().await;

    match msg.content {
        MessageContent::Join(payload) => {
            println!("User joined: {}", payload.username);
            let user_info = UserInfo {
                id: msg.client_id.clone(),
                username: payload.username.clone(),
                color: "#000000".to_string(),
            };
            guard.users.insert(msg.client_id.clone(), user_info.clone());
            if let Some(writer) = socket_writer.take() {
                guard.clients.insert(msg.client_id.clone(), writer);
            }

            let start = SystemTime::now();
            let timestamp = start
                .duration_since(UNIX_EPOCH)
                .expect("Time went backwards")
                .as_millis() as u64;

            let response = WebSocketMessage {
                client_id: msg.client_id.clone(),
                timestamp: timestamp,
                content: MessageContent::JoinGood(JoinGoodPayload {
                    session_active: true,
                    active_users: guard.users.values().cloned().collect(),
                    available_files: guard.files.keys().cloned().collect(),
                }),
            };

            send_message(&msg.client_id, &response, &mut guard.clients).await;
        }
        MessageContent::StartSession(payload) => {
            println!("User started session: {}", msg.client_id);

            if let Some(w) = socket_writer.take() {
                guard.clients.insert(msg.client_id.clone(), w);
            }

            for file in payload.files {
                guard.files.insert(file.path, file.content);
            }
        }
        MessageContent::EndSession(payload) => {
            println!(
                "User ended session: {} Reason: {}",
                msg.client_id, payload.reason
            );
            guard.clients.remove(&msg.client_id);
            guard.users.remove(&msg.client_id);
        }
        _ => {
            println!("Unhandled message type from client: {}", msg.client_id);
        }
    }
}

async fn send_message(
    client_id: &str,
    msg: &WebSocketMessage,
    clients: &mut HashMap<String, OwnedWriteHalf>,
) {
    if let Some(socket) = clients.get_mut(client_id) {
        let mut json = match serde_json::to_string(msg) {
            Ok(j) => j,
            Err(e) => {
                eprintln!("Error serializing message: {}", e);
                return;
            }
        };

        json.push('\n');

        if let Err(e) = socket.write_all(json.as_bytes()).await {
            eprintln!("Error sending message to {}: {}", client_id, e);
        }
    }
}
