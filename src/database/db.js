'use strict';
// Доступ к Supabase: все операции идут через серверные SQL-функции srv_* (см. supabase/migrations).
const { createRpc } = require('../../../backend/src/supabase');
module.exports = { createRpc };
