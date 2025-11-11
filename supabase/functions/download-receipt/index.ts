import { createClient } from "npm:@supabase/supabase-js@2.53.0";
import { jsPDF } from "npm:jspdf@2.5.1";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

interface InvoiceData {
  id: string;
  invoice_number: string;
  status: string;
  subtotal: number;
  tax: number;
  discount: number;
  total: number;
  currency: string;
  invoice_date: string;
  paid_at: string;
  period_start: string;
  period_end: string;
  payment_method: string;
  description: string;
  restaurant_name: string;
  user_email: string;
  plan_type: string;
  line_items: Array<{
    description: string;
    quantity: number;
    unit_price: number;
    amount: number;
  }>;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const url = new URL(req.url);
    const pathParts = url.pathname.split('/');
    const invoiceId = pathParts[pathParts.length - 1];

    if (!invoiceId) {
      throw new Error('Invoice ID is required');
    }

    console.log('Generating receipt for invoice:', invoiceId);

    const { data: invoice, error: invoiceError } = await supabase
      .from('invoices')
      .select(`
        *,
        invoice_line_items (*),
        user:users!invoices_user_id_fkey (email),
        subscription:subscriptions!invoices_subscription_id_fkey (plan_type)
      `)
      .eq('id', invoiceId)
      .single();

    if (invoiceError || !invoice) {
      console.error('Invoice fetch error:', invoiceError);
      throw new Error('Invoice not found');
    }

    console.log('Invoice data retrieved:', {
      id: invoice.id,
      number: invoice.invoice_number,
      total: invoice.total
    });

    const pdfBuffer = generatePDF({
      id: invoice.id,
      invoice_number: invoice.invoice_number || `INV-${invoice.id.slice(0, 8)}`,
      status: invoice.status,
      subtotal: parseFloat(invoice.subtotal) || 0,
      tax: parseFloat(invoice.tax) || 0,
      discount: parseFloat(invoice.discount) || 0,
      total: parseFloat(invoice.total) || 0,
      currency: invoice.currency || 'USD',
      invoice_date: invoice.invoice_date,
      paid_at: invoice.paid_at,
      period_start: invoice.period_start,
      period_end: invoice.period_end,
      payment_method: invoice.payment_method || 'Card',
      description: invoice.description || '',
      restaurant_name: invoice.restaurant_name || 'Restaurant',
      user_email: invoice.user?.email || 'customer@email.com',
      plan_type: invoice.subscription?.plan_type || 'monthly',
      line_items: invoice.invoice_line_items || []
    });

    console.log('PDF generated successfully');

    return new Response(pdfBuffer, {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/pdf',
        'Content-Disposition': `attachment; filename="Receipt-${invoice.invoice_number || invoiceId}.pdf"`,
        'Cache-Control': 'no-cache',
      },
    });
  } catch (error) {
    console.error('Error generating receipt:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});

function generatePDF(invoice: InvoiceData): Uint8Array {
  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: 'a4'
  });

  const pageWidth = doc.internal.pageSize.getWidth();
  const pageHeight = doc.internal.pageSize.getHeight();
  const margin = 20;
  const contentWidth = pageWidth - (2 * margin);

  const brandGradientStart = [230, 168, 92];
  const brandGradientMid = [232, 90, 155];
  const brandGradientEnd = [217, 70, 239];
  const darkGray = [31, 41, 55];
  const mediumGray = [107, 114, 128];
  const lightGray = [243, 244, 246];

  let yPos = margin;

  const headerHeight = 40;
  const gradientSteps = 50;
  for (let i = 0; i < gradientSteps; i++) {
    const ratio = i / gradientSteps;
    let r, g, b;

    if (ratio < 0.5) {
      const localRatio = ratio * 2;
      r = brandGradientStart[0] + (brandGradientMid[0] - brandGradientStart[0]) * localRatio;
      g = brandGradientStart[1] + (brandGradientMid[1] - brandGradientStart[1]) * localRatio;
      b = brandGradientStart[2] + (brandGradientMid[2] - brandGradientStart[2]) * localRatio;
    } else {
      const localRatio = (ratio - 0.5) * 2;
      r = brandGradientMid[0] + (brandGradientEnd[0] - brandGradientMid[0]) * localRatio;
      g = brandGradientMid[1] + (brandGradientEnd[1] - brandGradientMid[1]) * localRatio;
      b = brandGradientMid[2] + (brandGradientEnd[2] - brandGradientMid[2]) * localRatio;
    }

    doc.setFillColor(Math.round(r), Math.round(g), Math.round(b));
    doc.rect(
      0,
      i * (headerHeight / gradientSteps),
      pageWidth,
      headerHeight / gradientSteps + 0.5,
      'F'
    );
  }

  doc.setTextColor(255, 255, 255);
  doc.setFontSize(28);
  doc.setFont('helvetica', 'bold');
  doc.text('LEYLS', margin, yPos + 15);

  doc.setFontSize(10);
  doc.setFont('helvetica', 'normal');
  doc.text('Loyalty & Rewards Platform', margin, yPos + 22);

  doc.setFontSize(32);
  doc.setFont('helvetica', 'bold');
  const receiptText = 'RECEIPT';
  const receiptWidth = doc.getTextWidth(receiptText);
  doc.text(receiptText, pageWidth - margin - receiptWidth, yPos + 18);

  yPos = headerHeight + margin + 10;

  doc.setTextColor(...darkGray);
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('Invoice Details', margin, yPos);

  yPos += 7;
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9);
  doc.setTextColor(...mediumGray);

  const invoiceDetails = [
    ['Invoice Number:', invoice.invoice_number],
    ['Invoice Date:', formatDate(invoice.invoice_date)],
    ['Payment Date:', formatDate(invoice.paid_at)],
    ['Status:', invoice.status.toUpperCase()],
    ['Payment Method:', invoice.payment_method]
  ];

  invoiceDetails.forEach(([label, value]) => {
    doc.setFont('helvetica', 'bold');
    doc.text(label, margin, yPos);
    doc.setFont('helvetica', 'normal');
    doc.text(value, margin + 40, yPos);
    yPos += 5;
  });

  yPos += 5;

  doc.setFillColor(...lightGray);
  doc.roundedRect(margin, yPos, contentWidth, 25, 3, 3, 'F');

  yPos += 7;
  doc.setTextColor(...darkGray);
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('Bill To', margin + 5, yPos);

  yPos += 6;
  doc.setFontSize(9);
  doc.setFont('helvetica', 'normal');
  doc.setTextColor(...mediumGray);
  doc.text(invoice.restaurant_name, margin + 5, yPos);

  yPos += 5;
  doc.text(invoice.user_email, margin + 5, yPos);

  yPos += 15;

  doc.setTextColor(...darkGray);
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('Billing Period', margin, yPos);

  yPos += 6;
  doc.setFontSize(9);
  doc.setFont('helvetica', 'normal');
  doc.setTextColor(...mediumGray);
  doc.text(
    `${formatDate(invoice.period_start)} - ${formatDate(invoice.period_end)}`,
    margin,
    yPos
  );

  yPos += 10;

  doc.setTextColor(...darkGray);
  doc.setFontSize(10);
  doc.setFont('helvetica', 'bold');
  doc.text('Items', margin, yPos);

  yPos += 7;

  doc.setFillColor(...darkGray);
  doc.rect(margin, yPos, contentWidth, 8, 'F');

  doc.setTextColor(255, 255, 255);
  doc.setFontSize(9);
  doc.setFont('helvetica', 'bold');
  doc.text('Description', margin + 3, yPos + 5);
  doc.text('Qty', pageWidth - margin - 50, yPos + 5);
  doc.text('Unit Price', pageWidth - margin - 35, yPos + 5);
  doc.text('Amount', pageWidth - margin - 15, yPos + 5, { align: 'right' });

  yPos += 8;

  doc.setTextColor(...darkGray);
  doc.setFont('helvetica', 'normal');

  if (invoice.line_items && invoice.line_items.length > 0) {
    invoice.line_items.forEach((item, index) => {
      if (index % 2 === 0) {
        doc.setFillColor(...lightGray);
        doc.rect(margin, yPos, contentWidth, 8, 'F');
      }

      doc.text(item.description, margin + 3, yPos + 5);
      doc.text(item.quantity.toString(), pageWidth - margin - 50, yPos + 5);
      doc.text(formatCurrency(item.unit_price, invoice.currency), pageWidth - margin - 35, yPos + 5);
      doc.text(
        formatCurrency(item.amount, invoice.currency),
        pageWidth - margin - 3,
        yPos + 5,
        { align: 'right' }
      );

      yPos += 8;
    });
  } else {
    const planNames = {
      monthly: 'Monthly Subscription',
      semiannual: '6-Month Subscription',
      annual: 'Annual Subscription',
      trial: 'Trial Period'
    };

    doc.text(
      planNames[invoice.plan_type as keyof typeof planNames] || 'Subscription',
      margin + 3,
      yPos + 5
    );
    doc.text('1', pageWidth - margin - 50, yPos + 5);
    doc.text(
      formatCurrency(invoice.subtotal, invoice.currency),
      pageWidth - margin - 35,
      yPos + 5
    );
    doc.text(
      formatCurrency(invoice.subtotal, invoice.currency),
      pageWidth - margin - 3,
      yPos + 5,
      { align: 'right' }
    );

    yPos += 8;
  }

  yPos += 5;

  const totalsX = pageWidth - margin - 60;

  doc.setDrawColor(...mediumGray);
  doc.line(totalsX, yPos, pageWidth - margin, yPos);

  yPos += 7;

  doc.setFont('helvetica', 'normal');
  doc.setTextColor(...mediumGray);
  doc.text('Subtotal:', totalsX, yPos);
  doc.text(
    formatCurrency(invoice.subtotal, invoice.currency),
    pageWidth - margin - 3,
    yPos,
    { align: 'right' }
  );

  yPos += 6;

  if (invoice.tax > 0) {
    doc.text('Tax:', totalsX, yPos);
    doc.text(
      formatCurrency(invoice.tax, invoice.currency),
      pageWidth - margin - 3,
      yPos,
      { align: 'right' }
    );
    yPos += 6;
  }

  if (invoice.discount > 0) {
    doc.text('Discount:', totalsX, yPos);
    doc.text(
      `-${formatCurrency(invoice.discount, invoice.currency)}`,
      pageWidth - margin - 3,
      yPos,
      { align: 'right' }
    );
    yPos += 6;
  }

  doc.setDrawColor(...brandGradientMid);
  doc.setLineWidth(0.5);
  doc.line(totalsX, yPos, pageWidth - margin, yPos);

  yPos += 7;

  doc.setFontSize(12);
  doc.setFont('helvetica', 'bold');
  doc.setTextColor(...darkGray);
  doc.text('Total:', totalsX, yPos);

  doc.setTextColor(...brandGradientMid);
  doc.text(
    formatCurrency(invoice.total, invoice.currency),
    pageWidth - margin - 3,
    yPos,
    { align: 'right' }
  );

  const footerY = pageHeight - 30;

  doc.setDrawColor(...lightGray);
  doc.line(margin, footerY, pageWidth - margin, footerY);

  doc.setFontSize(8);
  doc.setFont('helvetica', 'normal');
  doc.setTextColor(...mediumGray);

  const footerText = 'Thank you for your business!';
  const footerWidth = doc.getTextWidth(footerText);
  doc.text(footerText, (pageWidth - footerWidth) / 2, footerY + 7);

  doc.setFontSize(7);
  doc.text(
    'This is a computer-generated receipt and does not require a signature.',
    (pageWidth - doc.getTextWidth('This is a computer-generated receipt and does not require a signature.')) / 2,
    footerY + 12
  );

  doc.text(
    'For support, contact: support@leyls.com',
    (pageWidth - doc.getTextWidth('For support, contact: support@leyls.com')) / 2,
    footerY + 17
  );

  const pdfOutput = doc.output('arraybuffer');
  return new Uint8Array(pdfOutput);
}

function formatDate(dateString: string): string {
  if (!dateString) return 'N/A';

  try {
    const date = new Date(dateString);
    return date.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  } catch {
    return 'N/A';
  }
}

function formatCurrency(amount: number, currency: string = 'USD'): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currency.toUpperCase(),
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(amount / 100);
}
