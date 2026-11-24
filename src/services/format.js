'use strict';
const { formatIdentifier, normalizeIdentifier } = require('../../backend/src/identifiers');

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

module.exports = { formatIdentifier, normalizeIdentifier, esc };
