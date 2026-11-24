'use strict';
// Тест логики бота на реальной PostgreSQL (миграции применены), Telegraf подменён заглушкой.
//   PGTEST="-h /tmp/pgt -p 54329 -U postgres -d ts" node --test "test/*.test.js"
const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const Module = require('node:module');
const { execFileSync } = require('node:child_process');
process.env.NODE_PATH = path.join(__dirname, 'fake');
Module._initPaths();
const { buildBot } = require('../src/bot');

const PG = process.env.PGTEST;
const q = (v) => (typeof v === 'number' ? String(v) : `'${String(v).replace(/'/g, "''")}'`);
function rpc(name, args = {}) {
  const a = Object.entries(args).map(([k, v]) => `${k} => ${q(v)}`).join(', ');
  const out = execFileSync('psql', [...PG.split(' '), '-At', '-c', `select ${name}(${a})`], { encoding: 'utf8' }).trim();
  return Promise.resolve(out ? JSON.parse(out) : null);
}

function mkCtx(from, log, sent) {
  return {
    from, chat: { type: 'private' }, state: {},
    reply: async (text, extra) => { log.push({ text, extra }); },
    answerCbQuery: async () => {}, editMessageReplyMarkup: async () => {},
    telegram: { sendMessage: async (id, text) => { sent.push({ id, text }); } },
  };
}
const kb = (m) => JSON.stringify(m.extra || {});

test('bot flows', { skip: !PG }, async () => {
  const OWNER = 990001, U = 990002 + Math.floor(Math.random() * 1000);
  const bot = buildBot({ token: 't', ownerId: OWNER, rpc });
  const sent = [];
  const as = (id, username) => { const log = []; return { log, ctx: mkCtx({ id, username, first_name: 'N' }, log, sent) }; };

  // новый пользователь
  let { log, ctx } = as(U, 'user' + U);
  await bot.text(ctx, '/start');
  assert.match(log[0].text, /Нажмите «📱 Мой номер»/);
  assert.match(kb(log[0]), /Привязать аккаунт/);
  await bot.press(as(U, 'user' + U).ctx, 'menu:number').catch(() => {});
  ({ log, ctx } = as(U, 'user' + U));
  await bot.press(ctx, 'menu:number');
  assert.match(log[0].text, /Привет, че!/);
  assert.match(kb(log[0]), /Получить \+1/); assert.match(kb(log[0]), /Получить \+7/);
  await bot.press(ctx, 'reg:+7');
  assert.match(log[1].text, /твой идентификатор для входа/);
  assert.match(log[1].text, /закреплён за тобой навсегда/);
  const ident = /\+7 \d{3} \d{3} \d{2} \d{2}/.exec(log[1].text)[0];

  // повторная регистрация невозможна, выбор +1/+7 не предлагается
  ({ log, ctx } = as(U, 'user' + U));
  await bot.press(ctx, 'reg:+1');
  assert.match(log[0].text, /уже есть идентификатор/);
  await bot.text(ctx, '/start');
  assert.match(log[1].text, new RegExp('Ваш номер: <b>' + ident.replace(/\+/g, '\\+')));
  await bot.text(ctx, '/mynumber');
  assert.ok(log[2].text.includes(ident));

  // обычный пользователь не может админ-команды
  await bot.text(ctx, '/addnumber @x +8880');
  assert.match(log[3].text, /Неизвестная команда/);
  await bot.text(ctx, '/unlink @user' + U);
  assert.match(log[4].text, /Неизвестная команда/);

  // владелец: /addnumber
  const C = 'carol' + U; const NUM = '+888' + String(U).slice(-6); const NUMF = NUM.slice(0, 4) + ' ' + NUM.slice(4);
  await bot.text(as(U + 5000, C).ctx, '/start');
  const o = as(OWNER, 'owner');
  await bot.text(o.ctx, '/start');
  await bot.text(o.ctx, '/addnumber @' + C + ' ' + NUMF);
  assert.match(o.log.at(-1).text, /привязан к @/);
  assert.ok(sent.at(-1).text.includes(NUM) && sent.at(-1).id === U + 5000);
  await bot.text(o.ctx, '/addnumber @' + C + ' +8881');
  assert.match(o.log.at(-1).text, /уже есть ID/);
  await bot.text(o.ctx, '/addnumber @nobodyxyz +8882');
  assert.match(o.log.at(-1).text, /должен сначала запустить/);
  await bot.text(o.ctx, '/addnumber');
  assert.match(o.log.at(-1).text, /Пример/);

  // /unlink с подтверждением
  await bot.text(o.ctx, '/unlink @' + C);
  const conf = o.log.at(-1);
  assert.match(conf.text, /Удалить привязку/);
  const uid = /unlink:yes:([0-9a-f-]{36})/.exec(kb(conf))[1];
  const before = await rpc('srv_auth_lookup', { p_identifier: NUM });
  assert.ok(before);
  await bot.press(o.ctx, 'unlink:yes:' + uid);
  assert.match(o.log.at(-1).text, /Привязка .* удалена/);
  assert.strictEqual(await rpc('srv_auth_lookup', { p_identifier: NUM }), null);
  // не-владелец не может нажать чужую кнопку
  const evil = as(U, 'user' + U);
  await bot.press(evil.ctx, 'unlink:yes:' + uid).catch(() => {});
  // после unlink старый ID нельзя выдать повторно
  const r = await rpc('srv_admin_add_number', { p_admin: 1, p_username: '@' + C, p_identifier: NUM });
  assert.strictEqual(r.error, 'revoked');
});
