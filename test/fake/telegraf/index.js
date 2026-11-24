'use strict';
// Мини-заглушка Telegraf для тестов без установки пакета (проверяет нашу логику хендлеров).
class Telegraf {
  constructor(token) { this.token = token; this.mw = []; this.cmds = {}; this.actions = []; }
  use(fn) { this.mw.push(fn); }
  start(fn) { this.cmds.start = fn; }
  command(n, fn) { this.cmds[n] = fn; }
  action(t, fn) { this.actions.push([t, fn]); }
  catch() {}
  async run(ctx, final) {
    let i = 0;
    const next = async () => (i < this.mw.length ? this.mw[i++](ctx, next) : final());
    return next();
  }
  async text(ctx, text) {
    ctx.message = { text };
    const m = /^\/(\w+)/.exec(text);
    return this.run(ctx, () => this.cmds[m[1]] && this.cmds[m[1]](ctx));
  }
  async press(ctx, data) {
    for (const [t, fn] of this.actions) {
      const match = t instanceof RegExp ? t.exec(data) : (t === data ? [data] : null);
      if (match) { ctx.match = match; return this.run(ctx, () => fn(ctx)); }
    }
    throw new Error('no action for ' + data);
  }
}
const Markup = {
  inlineKeyboard: (rows) => ({ reply_markup: { inline_keyboard: rows } }),
  button: { callback: (text, data) => ({ text, callback_data: data }) },
};
module.exports = { Telegraf, Markup };
