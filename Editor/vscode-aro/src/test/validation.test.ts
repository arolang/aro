/**
 * Unit tests for ARO path validation
 *
 * To run these tests, install mocha and sinon:
 * npm install --save-dev mocha @types/mocha sinon @types/sinon ts-node
 *
 * Then run: npm test
 */

import * as assert from 'assert';
import proxyquire = require('proxyquire');

// Note: For security tests, we use the real validateAroPath function.
// For valid path tests, we use proxyquire to mock file system operations.
import { validateAroPath } from '../validation';

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
            // Mock fs/promises and child_process using proxyquire
            const { validateAroPath } = proxyquire.load('../validation', {
                'fs/promises': {
                    realpath: async (path: string) => path,
                    access: async () => undefined,
                    constants: {
                        X_OK: 1
                    },
                    '@noCallThru': true
                },
                'child_process': {
                    execFile: (file: string, args: string[], options: any, callback: any) => {
                        // Simulate successful execution with version output
                        // Note: promisify expects (error, stdout, stderr) signature
                        process.nextTick(() => callback(null, 'aro version 1.0.0\n', ''));
                    },
                    '@noCallThru': true
                },
                'util': {
                    promisify: (fn: any) => {
                        return (...args: any[]) => {
                            return new Promise((resolve, reject) => {
                                fn(...args, (err: any, stdout: string, stderr: string) => {
                                    if (err) {
                                        reject(err);
                                    } else {
                                        resolve({ stdout, stderr });
                                    }
                                });
                            });
                        };
                    },
                    '@noCallThru': true
                }
            });

            const result = await validateAroPath('/usr/local/bin/aro');
            assert.strictEqual(result, true);
        });

        it('should accept paths with spaces (when properly quoted)', async () => {
            // Mock fs/promises and child_process using proxyquire
            const { validateAroPath } = proxyquire.load('../validation', {
                'fs/promises': {
                    realpath: async (path: string) => path,
                    access: async () => undefined,
                    constants: {
                        X_OK: 1
                    },
                    '@noCallThru': true
                },
                'child_process': {
                    execFile: (file: string, args: string[], options: any, callback: any) => {
                        // Simulate successful execution with version output
                        // Note: promisify expects (error, stdout, stderr) signature
                        process.nextTick(() => callback(null, 'aro version 1.0.0\n', ''));
                    },
                    '@noCallThru': true
                },
                'util': {
                    promisify: (fn: any) => {
                        return (...args: any[]) => {
                            return new Promise((resolve, reject) => {
                                fn(...args, (err: any, stdout: string, stderr: string) => {
                                    if (err) {
                                        reject(err);
                                    } else {
                                        resolve({ stdout, stderr });
                                    }
                                });
                            });
                        };
                    },
                    '@noCallThru': true
                }
            });

            const result = await validateAroPath('/usr/local/bin/aro with spaces/aro');
            assert.strictEqual(result, true);
        });

        it('should accept paths with hyphens and underscores', async () => {
            // Mock fs/promises and child_process using proxyquire
            const { validateAroPath } = proxyquire.load('../validation', {
                'fs/promises': {
                    realpath: async (path: string) => path,
                    access: async () => undefined,
                    constants: {
                        X_OK: 1
                    },
                    '@noCallThru': true
                },
                'child_process': {
                    execFile: (file: string, args: string[], options: any, callback: any) => {
                        // Simulate successful execution with version output
                        // Note: promisify expects (error, stdout, stderr) signature
                        process.nextTick(() => callback(null, 'aro version 1.0.0\n', ''));
                    },
                    '@noCallThru': true
                },
                'util': {
                    promisify: (fn: any) => {
                        return (...args: any[]) => {
                            return new Promise((resolve, reject) => {
                                fn(...args, (err: any, stdout: string, stderr: string) => {
                                    if (err) {
                                        reject(err);
                                    } else {
                                        resolve({ stdout, stderr });
                                    }
                                });
                            });
                        };
                    },
                    '@noCallThru': true
                }
            });

            const result = await validateAroPath('/usr/local/bin/aro-lang_v1');
            assert.strictEqual(result, true);
        });
    });
});

describe('ARO Version Pattern Validation', () => {
    // Match either "aro version X.Y.Z" or just "X.Y.Z" or "X.Y.Z-beta.N"
    const VERSION_PATTERN = /^(\d+\.\d+(\.\d+)?(-[a-zA-Z0-9.]+)?|aro\s+version\s+\d+\.\d+(\.\d+)?)/im;

    it('should match "ARO version 1.0.0"', () => {
        assert.strictEqual(VERSION_PATTERN.test('ARO version 1.0.0'), true);
    });

    it('should match "aro VERSION 2.5.3"', () => {
        assert.strictEqual(VERSION_PATTERN.test('aro VERSION 2.5.3'), true);
    });

    it('should match "Aro Version 1.2"', () => {
        assert.strictEqual(VERSION_PATTERN.test('Aro Version 1.2'), true);
    });

    it('should match "1.0.0" (just version number)', () => {
        assert.strictEqual(VERSION_PATTERN.test('1.0.0'), true);
    });

    it('should match "0.3.0-beta.11" (version with prerelease)', () => {
        assert.strictEqual(VERSION_PATTERN.test('0.3.0-beta.11'), true);
    });

    it('should not match "error in aro"', () => {
        assert.strictEqual(VERSION_PATTERN.test('error in aro'), false);
    });

    it('should not match "parameters: aro"', () => {
        assert.strictEqual(VERSION_PATTERN.test('parameters: aro'), false);
    });
});
