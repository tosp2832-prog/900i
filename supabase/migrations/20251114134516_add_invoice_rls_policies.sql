/*
  # Add RLS Policies for Invoices Table

  1. Problem
    - Invoices table had only service_role access
    - Authenticated users couldn't read their own invoices
    - Frontend couldn't fetch invoices for billing page

  2. Solution
    - Add SELECT policy for authenticated users to read their own invoices
    - Keep service_role policies for backend operations

  3. Security
    - Users can only read invoices where user_id matches their auth.uid()
    - Prevents cross-user data leakage
*/

-- First check if RLS is enabled
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- Drop existing policies to avoid conflicts
DROP POLICY IF EXISTS "Users can read own invoices" ON invoices;
DROP POLICY IF EXISTS "Service role can manage invoices" ON invoices;

-- Policy for authenticated users to read their own invoices
CREATE POLICY "Users can read own invoices"
  ON invoices
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Keep service role access for backend/webhooks
CREATE POLICY "Service role full access"
  ON invoices
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Also ensure line items are accessible
ALTER TABLE invoice_line_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own invoice line items" ON invoice_line_items;
DROP POLICY IF EXISTS "Service role can manage line items" ON invoice_line_items;

CREATE POLICY "Users can read own invoice line items"
  ON invoice_line_items
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM invoices
      WHERE invoices.id = invoice_line_items.invoice_id
      AND invoices.user_id = auth.uid()
    )
  );

CREATE POLICY "Service role full access"
  ON invoice_line_items
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);
