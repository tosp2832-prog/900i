/*
  # Invoice Generation System for Receipt Downloads

  1. Purpose
    - Automatically create invoices when subscriptions are activated or renewed
    - Populate invoice data with proper line items for PDF receipt generation
    - Ensure all subscription payments have corresponding invoice records

  2. New Functions
    - `generate_invoice_for_subscription`: Creates invoice with line items when subscription is created/updated
    - Automatically triggered on subscription changes

  3. Changes
    - Add trigger to auto-generate invoices on subscription webhook processing
    - Create helper function to generate invoice line items based on plan type

  4. Security
    - Functions run with security definer to allow proper invoice creation
    - RLS policies already exist on invoices table
*/

-- Function to generate invoice number
CREATE OR REPLACE FUNCTION generate_invoice_number()
RETURNS TEXT AS $$
DECLARE
  next_number INTEGER;
  invoice_num TEXT;
BEGIN
  SELECT COALESCE(MAX(CAST(SUBSTRING(invoice_number FROM 5) AS INTEGER)), 0) + 1
  INTO next_number
  FROM invoices
  WHERE invoice_number LIKE 'INV-%';
  
  invoice_num := 'INV-' || LPAD(next_number::TEXT, 6, '0');
  RETURN invoice_num;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get plan pricing
CREATE OR REPLACE FUNCTION get_plan_amount(plan_type TEXT)
RETURNS NUMERIC AS $$
BEGIN
  RETURN CASE plan_type
    WHEN 'monthly' THEN 299
    WHEN 'semiannual' THEN 999
    WHEN 'annual' THEN 1999
    WHEN 'trial' THEN 0
    ELSE 0
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to get plan description
CREATE OR REPLACE FUNCTION get_plan_description(plan_type TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN CASE plan_type
    WHEN 'monthly' THEN 'Monthly Subscription - Full Access'
    WHEN 'semiannual' THEN '6-Month Subscription - Full Access'
    WHEN 'annual' THEN 'Annual Subscription - Full Access + White Label'
    WHEN 'trial' THEN '30-Day Free Trial'
    ELSE 'Subscription'
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Main function to generate invoice for subscription
CREATE OR REPLACE FUNCTION generate_invoice_for_subscription(
  p_subscription_id UUID,
  p_user_id UUID,
  p_plan_type TEXT,
  p_period_start TIMESTAMPTZ,
  p_period_end TIMESTAMPTZ,
  p_stripe_payment_intent_id TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_invoice_id UUID;
  v_invoice_number TEXT;
  v_amount NUMERIC;
  v_restaurant_id UUID;
  v_restaurant_name TEXT;
BEGIN
  -- Get restaurant info
  SELECT id, name 
  INTO v_restaurant_id, v_restaurant_name
  FROM restaurants 
  WHERE owner_id = p_user_id 
  LIMIT 1;

  -- If no restaurant found, use user email
  IF v_restaurant_name IS NULL THEN
    SELECT email INTO v_restaurant_name
    FROM auth.users
    WHERE id = p_user_id;
  END IF;

  -- Calculate amount
  v_amount := get_plan_amount(p_plan_type);

  -- Generate invoice number
  v_invoice_number := generate_invoice_number();

  -- Create or update invoice
  INSERT INTO invoices (
    id,
    user_id,
    subscription_id,
    invoice_number,
    status,
    subtotal,
    tax,
    discount,
    total,
    currency,
    invoice_date,
    due_date,
    paid_at,
    period_start,
    period_end,
    payment_method,
    stripe_payment_intent_id,
    description,
    restaurant_id,
    restaurant_name,
    metadata,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    p_user_id,
    p_subscription_id,
    v_invoice_number,
    'paid',
    v_amount,
    0,
    0,
    v_amount,
    'USD',
    NOW(),
    NOW(),
    NOW(),
    p_period_start,
    p_period_end,
    'Card',
    p_stripe_payment_intent_id,
    get_plan_description(p_plan_type),
    v_restaurant_id,
    COALESCE(v_restaurant_name, 'Customer'),
    jsonb_build_object(
      'plan_type', p_plan_type,
      'auto_generated', true
    ),
    NOW(),
    NOW()
  )
  ON CONFLICT (subscription_id, period_start) 
  DO UPDATE SET
    status = EXCLUDED.status,
    paid_at = EXCLUDED.paid_at,
    updated_at = NOW()
  RETURNING id INTO v_invoice_id;

  -- Create line item for the invoice
  INSERT INTO invoice_line_items (
    id,
    invoice_id,
    description,
    quantity,
    unit_price,
    amount,
    item_type,
    created_at
  )
  VALUES (
    gen_random_uuid(),
    v_invoice_id,
    get_plan_description(p_plan_type),
    1,
    v_amount,
    v_amount,
    'subscription',
    NOW()
  )
  ON CONFLICT DO NOTHING;

  RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update the handle_subscription_webhook to also generate invoices
CREATE OR REPLACE FUNCTION handle_subscription_webhook(
  p_user_id UUID,
  p_plan_type TEXT,
  p_status TEXT,
  p_stripe_subscription_id TEXT,
  p_stripe_customer_id TEXT,
  p_period_start TEXT,
  p_period_end TEXT
)
RETURNS jsonb AS $$
DECLARE
  v_subscription_id UUID;
  v_invoice_id UUID;
  v_result jsonb;
  v_period_start_ts TIMESTAMPTZ;
  v_period_end_ts TIMESTAMPTZ;
  v_billing_period_text TEXT;
  v_duration_days INTEGER;
  v_is_accurate BOOLEAN;
BEGIN
  -- Parse timestamps
  v_period_start_ts := p_period_start::TIMESTAMPTZ;
  v_period_end_ts := COALESCE(p_period_end::TIMESTAMPTZ, v_period_start_ts + INTERVAL '30 days');

  -- Calculate duration and billing period text
  v_duration_days := EXTRACT(DAY FROM (v_period_end_ts - v_period_start_ts));
  
  v_billing_period_text := TO_CHAR(v_period_start_ts, 'Mon DD, YYYY') || ' - ' || 
                          TO_CHAR(v_period_end_ts, 'Mon DD, YYYY') || 
                          ' (' || v_duration_days || ' days)';

  -- Determine if period is accurate
  v_is_accurate := CASE p_plan_type
    WHEN 'monthly' THEN v_duration_days BETWEEN 28 AND 31
    WHEN 'semiannual' THEN v_duration_days BETWEEN 180 AND 186
    WHEN 'annual' THEN v_duration_days BETWEEN 360 AND 370
    WHEN 'trial' THEN v_duration_days BETWEEN 28 AND 32
    ELSE true
  END;

  -- Upsert subscription
  INSERT INTO subscriptions (
    user_id,
    plan_type,
    status,
    stripe_subscription_id,
    stripe_customer_id,
    current_period_start,
    current_period_end,
    billing_period_text,
    billing_period_accurate,
    created_at,
    updated_at
  )
  VALUES (
    p_user_id,
    p_plan_type::subscription_plan_type,
    p_status::subscription_status,
    p_stripe_subscription_id,
    p_stripe_customer_id,
    v_period_start_ts,
    v_period_end_ts,
    v_billing_period_text,
    v_is_accurate,
    NOW(),
    NOW()
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    plan_type = EXCLUDED.plan_type,
    status = EXCLUDED.status,
    stripe_subscription_id = COALESCE(EXCLUDED.stripe_subscription_id, subscriptions.stripe_subscription_id),
    stripe_customer_id = COALESCE(EXCLUDED.stripe_customer_id, subscriptions.stripe_customer_id),
    current_period_start = EXCLUDED.current_period_start,
    current_period_end = EXCLUDED.current_period_end,
    billing_period_text = EXCLUDED.billing_period_text,
    billing_period_accurate = EXCLUDED.billing_period_accurate,
    updated_at = NOW()
  RETURNING id INTO v_subscription_id;

  -- Generate invoice if status is active or paid
  IF p_status IN ('active', 'paid') THEN
    v_invoice_id := generate_invoice_for_subscription(
      v_subscription_id,
      p_user_id,
      p_plan_type,
      v_period_start_ts,
      v_period_end_ts,
      NULL
    );
  END IF;

  -- Return result
  v_result := jsonb_build_object(
    'subscription_id', v_subscription_id,
    'invoice_id', v_invoice_id,
    'billing_period_text', v_billing_period_text,
    'billing_period_accurate', v_is_accurate,
    'duration_days', v_duration_days
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Add unique constraint to prevent duplicate invoices for same period
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'invoices_subscription_period_unique'
  ) THEN
    ALTER TABLE invoices 
    ADD CONSTRAINT invoices_subscription_period_unique 
    UNIQUE (subscription_id, period_start);
  END IF;
END $$;

-- Backfill invoices for existing subscriptions that don't have them
DO $$
DECLARE
  sub RECORD;
BEGIN
  FOR sub IN 
    SELECT s.id, s.user_id, s.plan_type, s.current_period_start, s.current_period_end
    FROM subscriptions s
    LEFT JOIN invoices i ON i.subscription_id = s.id AND i.period_start = s.current_period_start
    WHERE i.id IS NULL
      AND s.status IN ('active', 'cancelled')
      AND s.plan_type != 'trial'
  LOOP
    PERFORM generate_invoice_for_subscription(
      sub.id,
      sub.user_id,
      sub.plan_type::TEXT,
      sub.current_period_start,
      sub.current_period_end,
      NULL
    );
  END LOOP;
END $$;
