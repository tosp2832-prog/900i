/*
  # Fix: Update handle_subscription_webhook to Generate Invoices

  1. Problem
    - The handle_subscription_webhook function was creating/updating subscriptions
    - But it was NOT calling generate_invoice_for_subscription
    - Result: 94 subscriptions with 0 invoices

  2. Solution
    - Update handle_subscription_webhook to call generate_invoice_for_subscription
    - Generate invoices for 'active' and 'paid' status subscriptions
    - Backfill all existing subscriptions that don't have invoices

  3. Changes
    - Replace handle_subscription_webhook with enhanced version that creates invoices
    - Add backfill logic to populate invoices for existing subscriptions
*/

DROP FUNCTION IF EXISTS public.handle_subscription_webhook(uuid, text, text, text, text, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.handle_subscription_webhook(
  p_user_id uuid,
  p_plan_type text,
  p_status text,
  p_stripe_subscription_id text DEFAULT NULL,
  p_stripe_customer_id text DEFAULT NULL,
  p_period_start timestamptz DEFAULT NULL,
  p_period_end timestamptz DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
  v_subscription_id uuid;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_plan_type subscription_plan_type;
  v_status subscription_status;
  v_invoice_id uuid;
  v_duration_days integer;
  v_billing_period_text text;
  v_is_accurate boolean;
  result jsonb;
BEGIN
  RAISE NOTICE 'Processing subscription webhook for user: %, plan: %, status: %', p_user_id, p_plan_type, p_status;
  
  -- Validate and cast plan type
  BEGIN
    v_plan_type := p_plan_type::subscription_plan_type;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Invalid plan type: %. Must be one of: trial, monthly, semiannual, annual', p_plan_type;
  END;
  
  -- Validate and cast status
  BEGIN
    v_status := p_status::subscription_status;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Invalid status: %. Must be one of: active, expired, cancelled, past_due', p_status;
  END;
  
  -- Calculate periods if not provided
  v_period_start := COALESCE(p_period_start, NOW());
  
  IF p_period_end IS NULL THEN
    CASE v_plan_type
      WHEN 'trial' THEN
        v_period_end := v_period_start + INTERVAL '30 days';
      WHEN 'monthly' THEN
        v_period_end := v_period_start + INTERVAL '1 month';
      WHEN 'semiannual' THEN
        v_period_end := v_period_start + INTERVAL '6 months';
      WHEN 'annual' THEN
        v_period_end := v_period_start + INTERVAL '1 year';
    END CASE;
  ELSE
    v_period_end := p_period_end;
  END IF;
  
  -- Calculate duration and billing period text
  v_duration_days := EXTRACT(DAY FROM (v_period_end - v_period_start))::integer;
  
  v_billing_period_text := TO_CHAR(v_period_start, 'Mon DD, YYYY') || ' - ' || 
                          TO_CHAR(v_period_end, 'Mon DD, YYYY') || 
                          ' (' || v_duration_days || ' days)';

  -- Determine if period is accurate
  v_is_accurate := CASE v_plan_type
    WHEN 'monthly' THEN v_duration_days BETWEEN 28 AND 31
    WHEN 'semiannual' THEN v_duration_days BETWEEN 180 AND 186
    WHEN 'annual' THEN v_duration_days BETWEEN 360 AND 370
    WHEN 'trial' THEN v_duration_days BETWEEN 28 AND 32
    ELSE true
  END;
  
  -- Check if subscription exists
  SELECT id INTO v_subscription_id
  FROM subscriptions
  WHERE user_id = p_user_id;
  
  IF v_subscription_id IS NOT NULL THEN
    -- Update existing subscription
    UPDATE subscriptions
    SET 
      plan_type = v_plan_type,
      status = v_status,
      stripe_subscription_id = COALESCE(p_stripe_subscription_id, stripe_subscription_id),
      stripe_customer_id = COALESCE(p_stripe_customer_id, stripe_customer_id),
      current_period_start = v_period_start,
      current_period_end = v_period_end,
      billing_period_text = v_billing_period_text,
      billing_period_accurate = v_is_accurate,
      updated_at = NOW()
    WHERE id = v_subscription_id;
    
    RAISE NOTICE 'Updated existing subscription: %', v_subscription_id;
  ELSE
    -- Create new subscription
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
    ) VALUES (
      p_user_id,
      v_plan_type,
      v_status,
      p_stripe_subscription_id,
      p_stripe_customer_id,
      v_period_start,
      v_period_end,
      v_billing_period_text,
      v_is_accurate,
      NOW(),
      NOW()
    ) RETURNING id INTO v_subscription_id;
    
    RAISE NOTICE 'Created new subscription: %', v_subscription_id;
  END IF;
  
  -- Generate invoice if status is active or paid
  IF v_status IN ('active'::subscription_status, 'paid'::subscription_status) THEN
    BEGIN
      v_invoice_id := generate_invoice_for_subscription(
        v_subscription_id,
        p_user_id,
        v_plan_type::text,
        v_period_start,
        v_period_end,
        p_stripe_subscription_id
      );
      RAISE NOTICE 'Invoice generated successfully: %', v_invoice_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to generate invoice: %', SQLERRM;
    END;
  END IF;
  
  -- Return result
  result := jsonb_build_object(
    'subscription_id', v_subscription_id,
    'invoice_id', v_invoice_id,
    'user_id', p_user_id,
    'plan_type', v_plan_type::text,
    'status', v_status::text,
    'period_start', v_period_start,
    'period_end', v_period_end,
    'billing_period_text', v_billing_period_text,
    'billing_period_accurate', v_is_accurate,
    'duration_days', v_duration_days,
    'processed_at', NOW()
  );
  
  RAISE NOTICE 'Webhook processing complete: %', result;
  RETURN result;
  
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Webhook processing failed: %', SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Backfill invoices for all existing active subscriptions that don't have invoices
DO $$
DECLARE
  sub RECORD;
  v_invoice_id UUID;
  backfill_count INTEGER := 0;
BEGIN
  RAISE NOTICE 'Starting backfill of invoices for existing subscriptions...';
  
  FOR sub IN 
    SELECT 
      s.id,
      s.user_id,
      s.plan_type,
      s.current_period_start,
      s.current_period_end,
      s.stripe_subscription_id
    FROM subscriptions s
    LEFT JOIN invoices i ON i.subscription_id = s.id AND i.period_start = s.current_period_start
    WHERE i.id IS NULL
      AND s.status IN ('active'::subscription_status)
      AND s.plan_type::text != 'trial'
    ORDER BY s.created_at DESC
  LOOP
    BEGIN
      v_invoice_id := generate_invoice_for_subscription(
        sub.id,
        sub.user_id,
        sub.plan_type::text,
        sub.current_period_start,
        sub.current_period_end,
        sub.stripe_subscription_id
      );
      backfill_count := backfill_count + 1;
      
      IF backfill_count % 10 = 0 THEN
        RAISE NOTICE 'Backfilled % invoices so far...', backfill_count;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to backfill invoice for subscription %: %', sub.id, SQLERRM;
    END;
  END LOOP;
  
  RAISE NOTICE 'Backfill complete. Total invoices created: %', backfill_count;
END $$;
