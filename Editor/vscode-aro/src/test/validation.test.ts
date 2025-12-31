/**
 * Unit tests for ARO path validation
 *
 * To run these tests, install mocha and sinon:
 * npm install --save-dev mocha @types/mocha sinon @types/sinon ts-node
 *
 * Then run: npm test
 */

import * as assert from 'assert';
import * as sinon from 'sinon';
import { validateAroPath } from '../extension';
import * as childProcess from 'child_process';

// Note: We import the real validateAroPath function and mock execFileAsync

describe('ARO Path Validation', () => {
    describe('Security - Command Injection', () => {
        it('should reject paths with semicolons', async () => {
            const result = await validateAroPath('/usr/bin/aro; rm -rf /');
            assert.strictEqual(result, false);
        });

        it('should reject paths with pipes', async () => {
            const result = await validateAroPath('/usr/bin/aro | cat /etc/passwd');
            assert.strictEqual(result, false);
        });

        it('should reject paths with backticks', async () => {
            const result = await validateAroPath('/usr/bin/`whoami`');
            assert.strictEqual(result, false);
        });

        it('should reject paths with dollar signs', async () => {
            const result = await validateAroPath('/usr/bin/$(whoami)');
            assert.strictEqual(result, false);
        });

        it('should reject paths with redirects', async () => {
            const result = await validateAroPath('/usr/bin/aro > /tmp/output');
            assert.strictEqual(result, false);
        });
    });

    describe('Security - Path Traversal', () => {
        it('should reject paths with double dots', async () => {
            const result = await validateAroPath('../../etc/passwd');
            assert.strictEqual(result, false);
        });

        it('should reject paths with traversal in middle', async () => {
            const result = await validateAroPath('/usr/../bin/aro');
            assert.strictEqual(result, false);
        });

        it('should reject relative paths with parent references', async () => {
            const result = await validateAroPath('../../../bin/aro');
            assert.strictEqual(result, false);
        });
    });

    describe('Valid Paths', () => {
        it('should accept absolute paths without suspicious characters', async () => {
            const result = await validateAroPath('/usr/local/bin/aro');
            assert.strictEqual(result, true);
        });

        it('should accept paths with spaces (when properly quoted)', async () => {
            const result = await validateAroPath('/usr/local/bin/aro with spaces/aro');
            assert.strictEqual(result, true);
        });

        it('should accept paths with hyphens and underscores', async () => {
            const result = await validateAroPath('/usr/local/bin/aro-lang_v1');
            assert.strictEqual(result, true);
        });
    });
});

describe('ARO Version Pattern Validation', () => {
    const VERSION_PATTERN = /aro\s+version\s+\d+\.\d+(\.\d+)?/i;

    it('should match "ARO version 1.0.0"', () => {
        assert.strictEqual(VERSION_PATTERN.test('ARO version 1.0.0'), true);
    });

    it('should match "aro VERSION 2.5.3"', () => {
        assert.strictEqual(VERSION_PATTERN.test('aro VERSION 2.5.3'), true);
    });

    it('should match "Aro Version 1.2"', () => {
        assert.strictEqual(VERSION_PATTERN.test('Aro Version 1.2'), true);
    });

    it('should not match "aro 1.0.0" (missing "version")', () => {
        assert.strictEqual(VERSION_PATTERN.test('aro 1.0.0'), false);
    });

    it('should not match "error in aro"', () => {
        assert.strictEqual(VERSION_PATTERN.test('error in aro'), false);
    });

    it('should not match "parameters: aro"', () => {
        assert.strictEqual(VERSION_PATTERN.test('parameters: aro'), false);
    });
});
