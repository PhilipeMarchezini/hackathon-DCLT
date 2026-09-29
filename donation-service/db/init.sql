CREATE TABLE IF NOT EXISTS donations (
    id SERIAL PRIMARY KEY,
    ngo_id INT NOT NULL,
    amount NUMERIC(10, 2) NOT NULL,
    donor_name VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL, -- Ex: APPROVED, PENDING
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS donation_outbox (
    id BIGSERIAL PRIMARY KEY,
    donation_id INT NOT NULL REFERENCES donations(id) ON DELETE CASCADE,
    payload JSONB NOT NULL,
    traceparent VARCHAR(128),
    published BOOLEAN NOT NULL DEFAULT FALSE,
    attempts INT NOT NULL DEFAULT 0,
    published_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_donation_outbox_pending
    ON donation_outbox (created_at) WHERE published = FALSE;
