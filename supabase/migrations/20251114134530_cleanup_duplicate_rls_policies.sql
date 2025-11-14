/*
  # Clean up duplicate RLS policies

  Removes redundant duplicate policies that were created during iterations
*/

DROP POLICY IF EXISTS "Users can view line items of their invoices" ON invoice_line_items;
DROP POLICY IF EXISTS "Super admins can manage all invoices" ON invoices;
DROP POLICY IF EXISTS "Users can view own invoices" ON invoices;
DROP POLICY IF EXISTS "Users can view their own invoices" ON invoices;
