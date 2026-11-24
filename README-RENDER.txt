TeleStar Telegram bot + API for Render

This repository root contains the Telegram bot source in /src and the required shared backend modules in /backend/src.
Android application files are intentionally not included or modified.

Render settings:
Build command: npm install
Start command: npm start
Node version: 26.13.1 (.node-version; package engines allow Node 20-26)

Required environment variables:
BOT_TOKEN
OWNER_TELEGRAM_ID
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
SUPABASE_JWT_SECRET
Optional: CODE_PEPPER, WEBHOOK_SECRET, WEBHOOK_URL

Apply the SQL migrations from the original project's supabase/migrations folder in Supabase before using the bot.
