-- Per-account chat schema. Owned and migrated in lockstep by the
-- chatstorage package. SQLCipher transparently encrypts every page,
-- so plaintext SQL here is fine — the file on disk is opaque.

CREATE TABLE conversations (
    id              TEXT PRIMARY KEY,
    account_uuid    TEXT NOT NULL,
    title           TEXT NOT NULL DEFAULT '',
    model           TEXT NOT NULL,
    system_prompt   TEXT NOT NULL DEFAULT '',
    archived        INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);
CREATE INDEX idx_conversations_account_updated
    ON conversations(account_uuid, updated_at DESC);

CREATE TABLE messages (
    id               TEXT PRIMARY KEY,
    conversation_id  TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role             TEXT NOT NULL,
    content_json     TEXT NOT NULL,
    plain_text       TEXT NOT NULL DEFAULT '',
    input_tokens     INTEGER NOT NULL DEFAULT 0,
    output_tokens    INTEGER NOT NULL DEFAULT 0,
    stop_reason      TEXT NOT NULL DEFAULT '',
    created_at       INTEGER NOT NULL
);
CREATE INDEX idx_messages_conversation_created
    ON messages(conversation_id, created_at);

-- FTS5 index over the plain_text projection. We feed it via triggers so
-- callers never touch the FTS table directly.
CREATE VIRTUAL TABLE messages_fts USING fts5(
    plain_text,
    content='messages',
    content_rowid='rowid'
);
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, plain_text) VALUES (new.rowid, new.plain_text);
END;
CREATE TRIGGER messages_fts_update AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, plain_text) VALUES ('delete', old.rowid, old.plain_text);
    INSERT INTO messages_fts(rowid, plain_text) VALUES (new.rowid, new.plain_text);
END;
CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, plain_text) VALUES ('delete', old.rowid, old.plain_text);
END;

CREATE TABLE attachments (
    id               TEXT PRIMARY KEY,
    conversation_id  TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    message_id       TEXT NOT NULL DEFAULT '',
    kind             TEXT NOT NULL,
    filename         TEXT NOT NULL,
    media_type       TEXT NOT NULL,
    size_bytes       INTEGER NOT NULL,
    file_path        TEXT NOT NULL,
    nonce_hex        TEXT NOT NULL,
    created_at       INTEGER NOT NULL
);
CREATE INDEX idx_attachments_conversation
    ON attachments(conversation_id);
CREATE INDEX idx_attachments_message
    ON attachments(message_id);
