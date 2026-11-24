'use strict';
// Нормализация и форматирование идентификаторов TeleStar.

function normalizeIdentifier(input) {
  if (typeof input !== 'string') return null;
  const s = input.replace(/[\s()\-]/g, '');
  return /^\+[0-9]{3,15}$/.test(s) ? s : null;
}

// +15552223267 -> "+1 555 222 3267"; +79123456789 -> "+7 912 345 67 89"; остальное как есть
function formatIdentifier(id) {
  if (!id) return '';
  let m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(id);
  if (m) return `+1 ${m[1]} ${m[2]} ${m[3]}`;
  m = /^\+7(\d{3})(\d{3})(\d{2})(\d{2})$/.exec(id);
  if (m) return `+7 ${m[1]} ${m[2]} ${m[3]} ${m[4]}`;
  return id;
}

module.exports = { normalizeIdentifier, formatIdentifier };
