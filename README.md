# DriveEase Admin Panel — HTML, CSS & JavaScript

A responsive, desktop-first admin panel based on the supplied DriveEase dashboard design. Files are separated so the UI, styling, Supabase configuration, and application logic can be maintained independently.

## Project structure

```text
driveease_admin_web/
├── index.html
├── css/
│   └── styles.css
├── js/
│   ├── config.js
│   └── app.js
├── sql/
│   └── driveease_supabase_schema.sql
└── assets/
    └── admin-reference.png
```

## Setup

1. Create or open your Supabase project.
2. In **SQL Editor**, run `sql/driveease_supabase_schema.sql` if you have not already created the DriveEase schema. If you already ran the same schema, do not rerun it just for this UI.
3. Open `js/config.js` and set your project's URL and **anon/publishable** key:

   ```js
   window.DRIVEEASE_CONFIG = {
     SUPABASE_URL: 'https://YOUR_PROJECT_ID.supabase.co',
     SUPABASE_ANON_KEY: 'YOUR_ANON_OR_PUBLISHABLE_KEY'
   };
   ```

4. Create a user using Supabase Authentication (email/password).
5. Grant that account the admin role. Run the following in the Supabase SQL Editor after replacing the email with the exact account email:

   ```sql
   update public.profiles p
   set role = 'admin'
   from auth.users u
   where p.id = u.id
     and lower(u.email) = lower('admin@example.com');
   ```

   Only an authorized project owner should grant admin privileges. Do not make admin role assignment available to ordinary customers.

6. Serve the folder from a local web server (recommended) instead of opening `index.html` as a `file://` URL. For example, if Python is installed, run this in the project directory:

   ```bash
   python -m http.server 5500
   ```

   Then visit `http://localhost:5500`. You can also use the VS Code Live Server extension.

## Features

- Supabase email/password sign-in and admin-role check.
- Dashboard metrics from database records: bookings, paid payments, active rentals, pending requests, and fleet availability.
- Booking list and status editing.
- Vehicle, location, add-on, and rental policy create/update/delete forms.
- Customer, payment, review, and rental agreement views; payment status editing.
- Reports and CSV export.
- App settings editor backed by `public.app_settings`.
- Responsive navigation, readable type, search/filter controls, pagination, confirmation prompts, and toast messages.

## Important security and data notes

- **Never put a Supabase `service_role` key or secret key in `js/config.js`.** Browser code is public. Use only the anon/publishable key.
- Keep Row Level Security (RLS) enabled. The logged-in account must have the appropriate admin policies on the tables it manages. A UI role check is not a substitute for database RLS.
- The schema is a starter schema; review its policies against your production requirements before deploying.
- Payment status editing only changes the database record. It does not charge, refund, or verify money with a payment provider.
- Foreign-key IDs are shown in some forms as IDs. A production polish pass could replace these with searchable dropdowns backed by vehicles, locations, and customer tables.
- This project loads Inter, Lucide icons, and Supabase JS from CDNs, so an internet connection is needed unless those libraries are self-hosted.

## Troubleshooting

- If login says the account is not an administrator, verify `profiles.role = 'admin'` for that account.
- If records fail to load or save, inspect the browser console and Supabase logs. Most commonly, RLS policies do not grant the authenticated admin access, or a field violates a database constraint.
- If the page says to configure Supabase, check `js/config.js` for placeholder values and confirm the URL/key pair belongs to the same project.
