# TeleStar Bot

Telegram-бот (Telegraf) + API авторизации для приложения TeleStar — один процесс, одна служба на Render.

* `src/index.js` — запуск: HTTP-сервер, webhook/polling, API `/auth/*`, `/health`
* `src/bot.js` — сборка бота, middleware, меню команд
* `src/commands/user.js` — /start, /mynumber, /linkaccount, /help, /cancel, кнопки, выдача +1/+7
* `src/commands/owner.js` — /addnumber, /unlink (только владелец, `OWNER_TELEGRAM_ID`)
* `src/database/db.js`, `src/services/` — доступ к Supabase и форматирование
* API (проверка кодов, токены) лежит в `../backend/src` и подключается этим же процессом.

Локальный запуск: `npm install`, скопировать `.env.example` в `.env` и заполнить, затем `node --env-file=.env src/index.js`
(без `WEBHOOK_URL` бот работает в режиме polling). Подробности — в `docs/INSTRUCTION_RU.md`.

Тесты (нужна локальная PostgreSQL с миграциями): `PGTEST="-h localhost -U postgres -d ts" npm test`.
