# AANDARI — Premium Customer App Starter

A mobile-first customer-facing PWA starter for the AANDARI hardware marketplace.

## Included
- Responsive navy, royal-blue and orange storefront
- Category browsing and product search
- Customer, Carpenter and Contractor demo price display
- Cart preview
- Voice search where supported by the browser
- Entry points for AI assistant, bulk quotation, product comparison, barcode scan, loyalty rewards and order tracking
- PWA manifest and basic service-worker shell

## Important status
This is a front-end starter with sample catalogue data. It is not production commerce yet. Authentication, server-authorized pricing tiers, database/catalogue, inventory, checkout, payment gateway, barcode lookup, AI service, quotation workflow, rewards ledger, notifications and order tracking need secure backend integrations.

Never trust a pricing tier or price sent by the browser. The backend must authenticate the customer and calculate applicable prices server-side. Use commercial invoices only until GST registration and configuration are complete.

## Run
Open index.html in a browser or deploy as a static site. For PWA installation, serve over HTTPS.


## Supabase setup (phone OTP + starter database)

1. In Supabase, open **Authentication → Providers → Phone** and enable phone sign-in.
2. Configure an SMS provider and its credentials in Supabase. SMS delivery is not enabled automatically by adding the frontend code; provider availability and charges depend on your provider/Supabase settings.
3. Open **SQL Editor → New query**, paste the contents of `supabase/schema.sql`, and run it.
4. In **Authentication → URL Configuration**, add the deployed GitHub Pages URL to the allowed site/redirect URLs:
   `https://mrsolankiyt-maker.github.io`
5. Open the deployed site and test with a phone number that your SMS provider can deliver to.

The browser contains only the Supabase publishable key. Never put a Supabase secret/service-role key in this repository. The SQL enables Row Level Security: customers can read their own profile and the public active catalogue, but cannot change their role or product prices.

## Current authentication status

The sign-in form now calls Supabase Phone OTP. It will only send SMS after Phone provider and an SMS delivery provider have been configured in the Supabase project. Product cards and pricing on the storefront are still sample/demo data; live catalogue, secure tier-based price display, checkout and order management are not connected yet.
