use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

mod types;
use tokio::net::tcp::OwnedWriteHalf;
use types::*;

struct FileData {
    content: Vec<String>,
    revision: u64,
    current_cursors: HashMap<String, RemoteCursor>,
}

struct AppState {
    clients: HashMap<String, OwnedWriteHalf>,
    users: HashMap<String, UserInfo>,
    files: HashMap<String, FileData>,
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
        let (socket, addr) = listener.accept().await?;
        println!("New connection from: {}", addr);

        let app_state = app_state.clone();

        tokio::spawn(async move {
            let (reader, writer) = socket.into_split();

            let mut client_id: Option<String> = None;
            let mut socket_writer = Some(writer);

            let mut buf_reader = BufReader::new(reader);

            let mut line = String::new();
            loop {
                line.clear();
                match buf_reader.read_line(&mut line).await {
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

                for file in state.files.values_mut() {
                    file.current_cursors.remove(&id);
                }
            }
        });
    }
}

fn get_random_color() -> String {
    let colors = [
        "#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FF00FF", "#00FFFF", "#FFA500", "#800080",
        "#008080", "#FFC0CB",
    ];

    let index = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(std::time::Duration::from_secs(0))
        .subsec_nanos() as usize
        % colors.len();

    colors[index].to_string()
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
                color: get_random_color(),
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
                timestamp,
                content: MessageContent::JoinGood(JoinGoodPayload {
                    session_active: true,
                    active_users: guard.users.values().cloned().collect(),
                    available_files: guard.files.keys().cloned().collect(),
                }),
            };

            println!("Sending JoinGood to {}", msg.client_id);
            println!("{:#?}", response);

            send_message(&msg.client_id, &response, &mut guard.clients).await;

            // Broadcast USER_JOINED to everyone else
            let join_notification = WebSocketMessage {
                client_id: "server".to_string(),
                timestamp,
                content: MessageContent::UserJoined(UserJoinedPayload {
                    user: user_info.clone(),
                }),
            };
            println!("Broadcasting USER_JOINED");
            broadcast_message(&msg.client_id, &join_notification, &mut guard.clients).await;
        }
        MessageContent::StartSession(payload) => {
            println!("User started session: {}", msg.client_id);

            let user_info = UserInfo {
                id: msg.client_id.clone(),
                username: msg.client_id.clone(),
                color: get_random_color(),
            };
            guard.users.insert(msg.client_id.clone(), user_info);

            if let Some(w) = socket_writer.take() {
                guard.clients.insert(msg.client_id.clone(), w);
            }

            for file in payload.files {
                let mut file_cursors = HashMap::new();

                if let Some(host_local_cursor) = file.my_cursor {
                    let remote = RemoteCursor {
                        client_id: msg.client_id.clone(),
                        pos: host_local_cursor.pos,
                        selection: host_local_cursor.selection,
                    };
                    file_cursors.insert(msg.client_id.clone(), remote);
                }

                guard.files.insert(
                    file.path,
                    FileData {
                        content: file.content,
                        revision: 0,
                        current_cursors: file_cursors,
                    },
                );
            }
        }
        MessageContent::Sync(payload) => {
            println!(
                "Received sync request from {} for file: {}",
                msg.client_id, payload.path
            );
            if let Some(file) = guard.files.get(&payload.path) {
                let timestamp = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .expect("Time went backwards")
                    .as_millis() as u64;

                let response = WebSocketMessage {
                    client_id: msg.client_id.clone(),
                    timestamp,
                    content: MessageContent::Sync(SyncPayload {
                        path: payload.path.clone(),
                        revision: Some(file.revision),
                        content: Some(file.content.clone()),
                        is_writeable: Some(true),
                        cursors: Some(file.current_cursors.values().cloned().collect()),
                    }),
                };

                send_message(&msg.client_id, &response, &mut guard.clients).await;
            } else {
                eprintln!("Warning: Sync requested for unknown file: {}", payload.path);
            }
        }

        MessageContent::EndSession(payload) => {
            println!(
                "User ended session: {} Reason: {}",
                msg.client_id, payload.reason
            );
            guard.clients.remove(&msg.client_id);
            guard.users.remove(&msg.client_id);

            for file in guard.files.values_mut() {
                file.current_cursors.remove(&msg.client_id);
            }
        }
        MessageContent::Edit(payload) => {
            println!(
                "Received edit from {}: rev.{}",
                msg.client_id, payload.revision
            );
            if let Some(file) = guard.files.get_mut(&payload.path) {
                apply_edit(&mut file.content, &payload.op);
            } else {
                eprintln!("Warning: Received edit for unknown file: {}", payload.path);
            }

            let broadcast_msg = WebSocketMessage {
                client_id: msg.client_id.clone(),
                timestamp: msg.timestamp,
                content: MessageContent::Edit(payload),
            };

            broadcast_message(&msg.client_id, &broadcast_msg, &mut guard.clients).await;
        }
        MessageContent::Cursor(payload) => {
            println!("Received cursor update from {}.", msg.client_id);

            let remote_cursor = RemoteCursor {
                client_id: msg.client_id.clone(),
                pos: payload.pos.clone(),
                selection: payload.selection.clone(),
            };

            if let Some(file) = guard.files.get_mut(&payload.path) {
                file.current_cursors
                    .insert(msg.client_id.clone(), remote_cursor);
            }

            let broadcast_msg = WebSocketMessage {
                client_id: msg.client_id.clone(),
                timestamp: msg.timestamp,
                content: MessageContent::Cursor(payload),
            };
            broadcast_message(&msg.client_id, &broadcast_msg, &mut guard.clients).await;
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

async fn broadcast_message(
    skip_client_id: &str,
    msg: &WebSocketMessage,
    clients: &mut HashMap<String, OwnedWriteHalf>,
) {
    let mut json = match serde_json::to_string(msg) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("Error serializing message: {}", e);
            return;
        }
    };

    json.push('\n');

    for (client_id, socket) in clients.iter_mut() {
        if client_id == skip_client_id {
            continue;
        }

        if let Err(e) = socket.write_all(json.as_bytes()).await {
            eprintln!("Error sending message to {}: {}", client_id, e);
        }
    }
}

fn apply_edit(lines: &mut Vec<String>, op: &EditOp) {
    if op.start.row > lines.len() || op.end.row > lines.len() {
        return;
    }

    if lines.is_empty() {
        lines.extend(op.text.clone());
        return;
    }

    let start_line = &lines[op.start.row];

    let prefix = if op.start.col <= start_line.len() {
        &start_line[..op.start.col]
    } else {
        start_line.as_str()
    };

    let suffix = if op.end.row == lines.len() {
        ""
    } else {
        let end_line = &lines[op.end.row];
        if op.end.col <= end_line.len() {
            &end_line[op.end.col..]
        } else {
            ""
        }
    };

    let mut new_text = Vec::new();
    if op.text.is_empty() {
        new_text.push(format!("{}{}", prefix, suffix));
    } else {
        let first_row = format!("{}{}", prefix, op.text[0]);

        new_text.push(first_row);

        for i in 1..op.text.len() {
            new_text.push(op.text[i].clone());
        }

        let last_index = new_text.len() - 1;
        new_text[last_index] = format!("{}{}", new_text[last_index], suffix);
    }

    if op.end.row == lines.len() {
        lines.splice(op.start.row..op.end.row, new_text);
    } else {
        lines.splice(op.start.row..=op.end.row, new_text);
    }

    println!("File after edit:");
    for (i, line) in lines.iter().enumerate() {
        println!("{:03}: {}", i + 1, line);
    }
}
