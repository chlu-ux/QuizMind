-- +goose Up

-- What the learner was looking at when the conversation began (the lesson or question, the bank, the
-- day), written out as the model is told it. It goes in front of the first message of every request
-- of the conversation, as part of what the learner said: the instructions stay one fixed text.
-- Empty for a conversation from before this column; it is written the next time it is spoken in.
ALTER TABLE agent_conversation ADD COLUMN briefing TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE agent_conversation DROP COLUMN briefing;
