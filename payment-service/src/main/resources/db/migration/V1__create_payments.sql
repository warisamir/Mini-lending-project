CREATE TABLE payments (
    id               UUID          PRIMARY KEY,
    idempotency_key  VARCHAR(64)   NOT NULL,
    request_hash     VARCHAR(64)   NOT NULL,
    loan_id          UUID          NOT NULL,
    user_id          UUID          NOT NULL,
    amount           NUMERIC(19,4) NOT NULL CHECK (amount > 0),
    currency         CHAR(3)       NOT NULL DEFAULT 'INR',
    status           VARCHAR(20)   NOT NULL,
    failure_reason   VARCHAR(255),
    version          BIGINT        NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT uq_payments_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT chk_payments_status CHECK (status IN ('CREATED','PROCESSING','SUCCESS','FAILED','PENDING'))
);

CREATE INDEX idx_payments_user_created ON payments (user_id, created_at DESC);
CREATE INDEX idx_payments_loan        ON payments (loan_id);
CREATE INDEX idx_payments_status      ON payments (status) WHERE status IN ('PROCESSING','PENDING');