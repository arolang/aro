import { execFile } from 'child_process';
import { promisify } from 'util';
import { realpath, access, constants } from 'fs/promises';

const execFileAsync = promisify(execFile);
const VALIDATION_TIMEOUT_MS = 5000;
const VERSION_PATTERN = /aro\s+version\s+\d+\.\d+(\.\d+)?/i;
const SUSPICIOUS_CHARS = /[;&|`$<>]/;

/**
 * Validate ARO binary path
 * Exported for testing
 */
export async function validateAroPath(path: string): Promise<boolean> {
    try {
        // Security: Check for suspicious characters that could indicate command injection
        if (SUSPICIOUS_CHARS.test(path)) {
            console.error(`ARO validation failed: Suspicious characters in path ${path}`);
            return false;
        }

        // Security: Prevent path traversal attacks
        if (path.includes('..')) {
            console.error(`ARO validation failed: Path traversal not allowed in ${path}`);
            return false;
        }

        // Security: Resolve to canonical path to prevent path traversal
        // Note: We don't check basename because legitimate symlinks may have different names
        // The ".." check above provides sufficient path traversal protection
        try {
            const canonicalPath = await realpath(path);

            // Verify file exists and is executable
            await access(canonicalPath, constants.X_OK);
        } catch (error: any) {
            console.error(`ARO validation failed: Invalid path ${path}: ${error.message}`);
            return false;
        }

        const { stdout } = await execFileAsync(path, ['--version'], {
            timeout: VALIDATION_TIMEOUT_MS
        });

        // Improved validation: Check for specific version format instead of just "aro"
        const isValid = VERSION_PATTERN.test(stdout);

        if (!isValid) {
            console.error(`ARO validation failed: Invalid version output from ${path}`);
            console.error(`Output: ${stdout}`);
        }

        return isValid;
    } catch (error: any) {
        // Distinguish timeout errors from other errors
        if (error.killed && error.signal === 'SIGTERM') {
            console.error(`ARO validation timeout for path ${path} (exceeded ${VALIDATION_TIMEOUT_MS}ms)`);
        } else {
            const message = error.message || String(error);
            console.error(`ARO validation failed for path ${path}: ${message}`);

            // Include stdout/stderr if available for debugging
            if (error.stdout) {
                console.error(`stdout: ${error.stdout}`);
            }
            if (error.stderr) {
                console.error(`stderr: ${error.stderr}`);
            }
        }
        return false;
    }
}
