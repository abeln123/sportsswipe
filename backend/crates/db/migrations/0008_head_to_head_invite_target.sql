-- Preserve the original invite target after an open invitation is accepted.
ALTER TABLE head_to_heads ADD COLUMN invited_user_id UUID REFERENCES users(id);
UPDATE head_to_heads SET invited_user_id = CASE WHEN thread_id IS NOT NULL OR accepted_at IS NULL THEN opponent_id ELSE NULL END;
