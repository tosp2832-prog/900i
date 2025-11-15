/*
  # Fix Subscriptions RLS Policies

  1. Problem
    - "Users can manage own subscriptions" policy doesn't explicitly check user ownership
    - Could allow unauthorized access patterns
    - Need explicit user_id matching for SELECT/UPDATE

  2. Solution
    - Replace generic ALL policy with explicit CRUD policies
    - Add restrictive WHERE conditions that check auth.uid() = user_id
    - Keep service_role unrestricted for webhooks

  3. Security
    - Users can only read/update their own subscriptions
    - Service role maintains full access for webhook operations
*/

-- Drop old permissive policy
DROP POLICY IF EXISTS "Users can manage own subscriptions" ON subscriptions;

-- Add explicit SELECT policy for users
CREATE POLICY "Users can read own subscriptions"
  ON subscriptions
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Add explicit INSERT policy (for subscriptions created via webhooks as authenticated user)
CREATE POLICY "Authenticated users can insert own subscriptions"
  ON subscriptions
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Add explicit UPDATE policy for users
CREATE POLICY "Users can update own subscriptions"
  ON subscriptions
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Add explicit DELETE policy for users
CREATE POLICY "Users can delete own subscriptions"
  ON subscriptions
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- Ensure service role policy exists
DROP POLICY IF EXISTS "Service role can manage all subscriptions" ON subscriptions;

CREATE POLICY "Service role full access"
  ON subscriptions
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);
