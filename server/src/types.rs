use serde::{Deserialize, Serialize};

// --- Basic Types ---

/// Represents a position as [row, col] used in most cursor messages.
pub type CursorPosition = (usize, usize);

/// Represents a selection range with start and end positions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Selection {
    pub start: CursorPosition,
    pub end: CursorPosition,
}

/// Represents a cursor without user info (used in START_SESSION, CURSOR payload).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalCursor {
    pub pos: CursorPosition,
    pub selection: Option<Selection>,
}

/// Represents a cursor belonging to a specific client (used in SYNC).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteCursor {
    pub client_id: String,
    pub pos: CursorPosition,
    pub selection: Option<Selection>,
}

/// Represents a position as { row, col } used in EDIT operations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObjPosition {
    pub row: usize,
    pub col: usize,
}

/// Represents an edit operation (delta).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditOp {
    pub start: ObjPosition,
    pub end: ObjPosition,
    pub text: Vec<String>,
}

// --- Payload Structures ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileState {
    pub path: String,
    pub content: Vec<String>,
    pub is_writeable: bool,
    /// Host's cursor in this file
    pub my_cursor: Option<LocalCursor>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartSessionPayload {
    pub project_name: String,
    pub files: Vec<FileState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndSessionPayload {
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JoinPayload {
    pub username: String,
    pub client_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserInfo {
    pub id: String,
    pub username: String,
    pub color: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JoinGoodPayload {
    pub session_active: bool,
    pub active_users: Vec<UserInfo>,
    pub available_files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserJoinedPayload {
    pub user: UserInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserLeftPayload {
    pub user_id: String,
    pub username: String,
    pub reason: Option<String>, // "optional" in protocol
}

/// Payload for SYNC message.
///
/// This structure handles both the request (Guest -> Server) and response (Server -> Guest).
/// - Request: `path` is required.
/// - Response: `path`, `revision`, `content`, `is_writeable`, `cursors` are populated.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncPayload {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_writeable: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursors: Option<Vec<RemoteCursor>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditPayload {
    pub path: String,
    pub revision: u64,
    pub op: EditOp,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CursorPayload {
    pub path: String,
    pub pos: CursorPosition,
    pub selection: Option<Selection>,
}

// --- Main Message Enum ---

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum MessageContent {
    #[serde(rename = "START_SESSION")]
    StartSession(StartSessionPayload),
    #[serde(rename = "END_SESSION")]
    EndSession(EndSessionPayload),
    #[serde(rename = "JOIN")]
    Join(JoinPayload),
    #[serde(rename = "JOIN_GOOD")]
    JoinGood(JoinGoodPayload),
    #[serde(rename = "USER_JOINED")]
    UserJoined(UserJoinedPayload),
    #[serde(rename = "USER_LEFT")]
    UserLeft(UserLeftPayload),
    #[serde(rename = "SYNC")]
    Sync(SyncPayload),
    #[serde(rename = "EDIT")]
    Edit(EditPayload),
    #[serde(rename = "CURSOR")]
    Cursor(CursorPayload),
}

/// The top-level WebSocket message structure.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSocketMessage {
    pub client_id: String,
    pub timestamp: u64,
    #[serde(flatten)]
    pub content: MessageContent,
}
