-- ============================================================================
-- SubWatch — Household Subscription Optimizer — Schema (PostgreSQL 14+)
-- ============================================================================
-- Core ideas:
--   * Subscriptions belong to HOUSEHOLDS, not just individuals. A subscription
--     has one payer and a set of members who share it (subscription_members).
--   * Services have multiple PLANS (individual / student / duo / family), each
--     with a member capacity — this is what makes family-plan consolidation and
--     cost splitting possible.
--   * ENTITLEMENTS form a graph: a plan can include other plans (a telecom plan
--     includes Amazon Prime, which includes Prime Video). detection.sql walks
--     this graph with a recursive CTE to find services people pay for twice.
--   * Business rules that a CHECK constraint can't express (capacity limits,
--     same-household sharing, non-purchasable plans) are enforced by triggers.
-- ============================================================================

SET client_min_messages = warning;

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- ---------------------------------------------------------------------------
-- people and households
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    user_id         SERIAL PRIMARY KEY,
    full_name       VARCHAR(100) NOT NULL,
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   VARCHAR(255) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE households (
    household_id    SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    monthly_budget  NUMERIC(10,2) CHECK (monthly_budget IS NULL OR monthly_budget >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- a user belongs to at most one household (UNIQUE on user_id)
CREATE TABLE household_members (
    household_id    INT NOT NULL REFERENCES households(household_id) ON DELETE CASCADE,
    user_id         INT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
    role            VARCHAR(10) NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
    joined_at       DATE NOT NULL DEFAULT CURRENT_DATE,
    PRIMARY KEY (household_id, user_id)
);

-- ---------------------------------------------------------------------------
-- catalog: categories -> services -> plans
-- ---------------------------------------------------------------------------
-- is_passive: things you "use" all the time without opening them (a phone
-- plan, cloud backup). Waste and churn detection skip these.
CREATE TABLE categories (
    category_id     SERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,
    is_passive      BOOLEAN NOT NULL DEFAULT false
);

CREATE TABLE services (
    service_id      SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL UNIQUE,
    category_id     INT NOT NULL REFERENCES categories(category_id),
    website         VARCHAR(255)
);
CREATE INDEX idx_services_category ON services(category_id);

-- 'included' plans are not sold on their own; they only exist as the target
-- of an entitlement (e.g. "Prime Video, included with Prime")
CREATE TABLE plans (
    plan_id         SERIAL PRIMARY KEY,
    service_id      INT NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    name            VARCHAR(100) NOT NULL,
    tier            VARCHAR(10) NOT NULL
                     CHECK (tier IN ('individual','student','duo','family','included')),
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    billing_cycle   VARCHAR(10) NOT NULL DEFAULT 'monthly'
                     CHECK (billing_cycle IN ('weekly','monthly','quarterly','yearly')),
    max_members     INT NOT NULL DEFAULT 1 CHECK (max_members >= 1),
    is_purchasable  BOOLEAN NOT NULL DEFAULT true,
    monthly_price   NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE billing_cycle
            WHEN 'weekly'    THEN ROUND(price * 52 / 12, 2)
            WHEN 'monthly'   THEN price
            WHEN 'quarterly' THEN ROUND(price / 3, 2)
            WHEN 'yearly'    THEN ROUND(price / 12, 2)
        END
    ) STORED,
    UNIQUE (service_id, name),
    CHECK (tier <> 'included' OR (is_purchasable = false AND price = 0))
);
CREATE INDEX idx_plans_service ON plans(service_id);

-- entitlement graph: plan_id includes included_plan_id (a directed edge)
CREATE TABLE entitlements (
    plan_id           INT NOT NULL REFERENCES plans(plan_id) ON DELETE CASCADE,
    included_plan_id  INT NOT NULL REFERENCES plans(plan_id) ON DELETE CASCADE,
    PRIMARY KEY (plan_id, included_plan_id),
    CHECK (plan_id <> included_plan_id)
);
CREATE INDEX idx_entitlements_included ON entitlements(included_plan_id);

-- ---------------------------------------------------------------------------
-- subscriptions and who shares them
-- ---------------------------------------------------------------------------
CREATE TABLE subscriptions (
    subscription_id SERIAL PRIMARY KEY,
    payer_id        INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    plan_id         INT NOT NULL REFERENCES plans(plan_id),
    start_date      DATE NOT NULL,
    end_date        DATE,
    status          VARCHAR(10) NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','cancelled','paused')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_subscriptions_payer ON subscriptions(payer_id);
CREATE INDEX idx_subscriptions_plan ON subscriptions(plan_id);

CREATE TABLE subscription_members (
    subscription_id INT NOT NULL REFERENCES subscriptions(subscription_id) ON DELETE CASCADE,
    user_id         INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    added_at        DATE NOT NULL DEFAULT CURRENT_DATE,
    PRIMARY KEY (subscription_id, user_id)
);
CREATE INDEX idx_subscription_members_user ON subscription_members(user_id);

-- composite FK: only someone who is actually a member of the subscription can
-- log usage against it
CREATE TABLE usage_logs (
    usage_log_id     BIGSERIAL PRIMARY KEY,
    subscription_id  INT NOT NULL,
    user_id          INT NOT NULL,
    used_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    duration_minutes INT CHECK (duration_minutes IS NULL OR duration_minutes >= 0),
    FOREIGN KEY (subscription_id, user_id)
        REFERENCES subscription_members(subscription_id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_usage_logs_sub_time ON usage_logs(subscription_id, used_at);

-- ---------------------------------------------------------------------------
-- alerts — persisted optimizer output. fingerprint identifies "the same
-- finding" across refreshes, so a dismissed alert stays dismissed.
-- An alert can involve any number of subscriptions (a family-plan suggestion
-- covers 3 people's plans), so that link lives in alert_subscriptions rather
-- than in a fixed number of columns here.
-- ---------------------------------------------------------------------------
CREATE TABLE alerts (
    alert_id                  SERIAL PRIMARY KEY,
    household_id              INT NOT NULL REFERENCES households(household_id) ON DELETE CASCADE,
    alert_type                VARCHAR(20) NOT NULL
                               CHECK (alert_type IN ('hidden_duplicate','consolidation','spare_capacity',
                                                     'bundle','churn_risk','waste','overlap')),
    recommended_plan_id       INT REFERENCES plans(plan_id) ON DELETE CASCADE,
    fingerprint               TEXT NOT NULL,
    message                   TEXT NOT NULL,
    potential_monthly_savings NUMERIC(10,2) CHECK (potential_monthly_savings IS NULL OR potential_monthly_savings >= 0),
    status                    VARCHAR(10) NOT NULL DEFAULT 'open'
                               CHECK (status IN ('open','dismissed','resolved')),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (household_id, fingerprint)
);
CREATE INDEX idx_alerts_household_status ON alerts(household_id, status);

-- which subscriptions an alert is about. role 'subject' = the subscription the
-- advice is about (cancel/merge/switch this one); 'source' = the subscription
-- that explains it (e.g. the telecom plan that already includes the service)
CREATE TABLE alert_subscriptions (
    alert_id         INT NOT NULL REFERENCES alerts(alert_id) ON DELETE CASCADE,
    subscription_id  INT NOT NULL REFERENCES subscriptions(subscription_id) ON DELETE CASCADE,
    role             VARCHAR(10) NOT NULL CHECK (role IN ('subject','source')),
    PRIMARY KEY (alert_id, subscription_id)
);
CREATE INDEX idx_alert_subscriptions_sub ON alert_subscriptions(subscription_id);

-- ---------------------------------------------------------------------------
-- bank statement import
-- ---------------------------------------------------------------------------
-- regex patterns (matched against a cleaned-up transaction description) that
-- identify a catalog service. One pattern can point at several services
-- ("APPLE.COM/BILL" could be Apple Music, Apple TV+, iCloud+...); the charge
-- amount narrows it down to a plan later.
CREATE TABLE merchant_aliases (
    pattern     TEXT NOT NULL,
    service_id  INT NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    PRIMARY KEY (pattern, service_id)
);

-- one uploaded statement. The household isn't stored here — it follows from
-- the user (household_members), so storing it would be a transitive dependency.
CREATE TABLE statement_imports (
    import_id    SERIAL PRIMARY KEY,
    user_id      INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    file_name    VARCHAR(255),
    imported_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- positive amount = money going out
CREATE TABLE bank_transactions (
    txn_id       BIGSERIAL PRIMARY KEY,
    import_id    INT NOT NULL REFERENCES statement_imports(import_id) ON DELETE CASCADE,
    txn_date     DATE NOT NULL,
    description  TEXT NOT NULL,
    amount       NUMERIC(12,2) NOT NULL CHECK (amount <> 0)
);
CREATE INDEX idx_bank_transactions_import ON bank_transactions(import_id, txn_date);

-- ============================================================================
-- Triggers
-- ============================================================================

-- keep subscriptions.updated_at current
CREATE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- a subscription must be for a purchasable plan, and its payer must belong
-- to a household
CREATE FUNCTION validate_subscription() RETURNS TRIGGER AS $$
BEGIN
    IF NOT (SELECT is_purchasable FROM plans WHERE plan_id = NEW.plan_id) THEN
        RAISE EXCEPTION 'Plan % is not sold on its own (it only comes included with another plan)', NEW.plan_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM household_members WHERE user_id = NEW.payer_id) THEN
        RAISE EXCEPTION 'User % is not part of any household', NEW.payer_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_subscription
    BEFORE INSERT OR UPDATE OF plan_id, payer_id ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION validate_subscription();

-- the payer is always a member of their own subscription
CREATE FUNCTION enrol_payer() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO subscription_members (subscription_id, user_id)
    VALUES (NEW.subscription_id, NEW.payer_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enrol_payer
    AFTER INSERT ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION enrol_payer();

-- sharing rules: a plan can't exceed its member capacity, and you can only
-- share with people in the payer's household. The parent row is locked
-- FOR UPDATE so two people joining at the same moment can't both squeeze
-- into the last slot.
CREATE FUNCTION check_member_rules() RETURNS TRIGGER AS $$
DECLARE
    v_max      INT;
    v_count    INT;
    v_payer_hh INT;
    v_new_hh   INT;
BEGIN
    SELECT p.max_members, hm.household_id
      INTO v_max, v_payer_hh
      FROM subscriptions s
      JOIN plans p ON p.plan_id = s.plan_id
      JOIN household_members hm ON hm.user_id = s.payer_id
     WHERE s.subscription_id = NEW.subscription_id
       FOR UPDATE OF s;

    SELECT household_id INTO v_new_hh FROM household_members WHERE user_id = NEW.user_id;
    IF v_new_hh IS DISTINCT FROM v_payer_hh THEN
        RAISE EXCEPTION 'User % is not in the same household as the payer', NEW.user_id
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COUNT(*) INTO v_count FROM subscription_members WHERE subscription_id = NEW.subscription_id;
    IF v_count >= v_max THEN
        RAISE EXCEPTION 'This plan allows at most % member(s) and is already full', v_max
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_member_rules
    BEFORE INSERT ON subscription_members
    FOR EACH ROW EXECUTE FUNCTION check_member_rules();

-- the payer can't be removed from their own subscription (but a cascade from
-- deleting the subscription itself is fine — the parent is already gone then)
CREATE FUNCTION protect_payer_membership() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM subscriptions
                WHERE subscription_id = OLD.subscription_id AND payer_id = OLD.user_id) THEN
        RAISE EXCEPTION 'The payer cannot be removed from their own subscription'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_payer_membership
    BEFORE DELETE ON subscription_members
    FOR EACH ROW EXECUTE FUNCTION protect_payer_membership();

-- ============================================================================
-- Turn off JIT compilation for this database. The optimizer views are nested
-- several levels deep, so the planner's cost estimate gets wildly inflated
-- (millions) even though the real query takes ~40 ms — and that estimate
-- makes Postgres spend ~13 s compiling the query with LLVM before running it.
-- JIT only pays off for huge analytical scans, never at this size.
-- (Takes effect for new connections.)
-- ============================================================================
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET jit = off', current_database());
END;
$$;
