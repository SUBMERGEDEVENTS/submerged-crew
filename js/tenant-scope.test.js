#!/usr/bin/env node
var assert = require('assert');
var scope = require('./tenant-scope.js');

assert.strictEqual(scope.isValidSlug('submerged'), true);
assert.strictEqual(scope.isValidSlug('acme-demo'), true);
assert.strictEqual(scope.isValidSlug(''), false);
assert.strictEqual(scope.isValidSlug('Bad_Slug'), false);
assert.strictEqual(scope.isValidSlug('a'), true);
assert.strictEqual(scope.filterFor(''), null);
assert.strictEqual(scope.filterFor('nope_invalid'), null);

var sub = scope.filterFor('submerged');
assert.deepStrictEqual(sub, {
  type: 'or',
  value: 'tenant_slug.eq.submerged,tenant_slug.is.null'
});
assert.deepStrictEqual(scope.filterFor('SUBMERGED'), sub);

var acme = scope.filterFor('acme-demo');
assert.deepStrictEqual(acme, { type: 'eq', column: 'tenant_slug', value: 'acme-demo' });

var calls = [];
var fakeQuery = {
  or: function (v) { calls.push(['or', v]); return 'OR'; },
  eq: function (c, v) { calls.push(['eq', c, v]); return 'EQ'; }
};
assert.strictEqual(scope.apply(fakeQuery, 'submerged'), 'OR');
assert.strictEqual(scope.apply(fakeQuery, 'acme-demo'), 'EQ');
assert.throws(function () { scope.apply(fakeQuery, ''); }, /Refusing unscoped query/);

var stamped = scope.withTenant({ name: 'Show' }, 'submerged');
assert.deepStrictEqual(stamped, { name: 'Show', tenant_slug: 'submerged' });
assert.throws(function () { scope.withTenant({ name: 'Show' }, ''); }, /Refusing write/);

console.log('tenant-scope tests passed');
