import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from 'vscode-languageclient/node';
import { validateAroPath } from './validation';

let client: LanguageClient | undefined;
let statusBarItem: vscode.StatusBarItem;

export function activate(context: vscode.ExtensionContext) {
    // Create status bar item for LSP connection state
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBarItem.command = 'aro.openSettings';
    context.subscriptions.push(statusBarItem);
    const config = vscode.workspace.getConfiguration('aro.lsp');
    const enabled = config.get<boolean>('enabled', true);

    if (!enabled) {
        console.log('ARO Language Server is disabled');
        statusBarItem.text = '$(circle-slash) ARO LSP: Disabled';
        statusBarItem.tooltip = 'ARO Language Server is disabled. Click to configure.';
        statusBarItem.show();
        return;
    }

    const aroPath = config.get<string>('path', 'aro');
    const debug = config.get<boolean>('debug', false);

    console.log(`ARO LSP: Using path: ${aroPath}, debug: ${debug}`);

    // Server options - run the ARO language server
    const serverOptions: ServerOptions = {
        command: aroPath,
        args: debug ? ['lsp', '--debug'] : ['lsp'],
        options: {
            shell: false,
            env: { ...process.env, PATH: process.env.PATH + ':/opt/homebrew/bin:/usr/local/bin' }
        }
    };

    // Create output channel for logging
    const outputChannel = vscode.window.createOutputChannel('ARO Language Server');
    outputChannel.appendLine(`Starting ARO Language Server...`);
    outputChannel.appendLine(`Path: ${aroPath}`);
    outputChannel.appendLine(`Debug: ${debug}`);

    // Client options
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'aro' }],
        outputChannel: outputChannel,
        traceOutputChannel: outputChannel
    };

    // Create and start the language client
    client = new LanguageClient(
        'aro',
        'ARO Language Server',
        serverOptions,
        clientOptions
    );

    // Update status: connecting
    statusBarItem.text = '$(sync~spin) ARO LSP: Connecting...';
    statusBarItem.tooltip = 'Connecting to ARO Language Server';
    statusBarItem.show();

    // Start the client
    client.start().then(() => {
        console.log('ARO Language Server started successfully');

        // Update status: connected
        statusBarItem.text = '$(check) ARO LSP: Connected';
        statusBarItem.tooltip = 'ARO Language Server is running';
        statusBarItem.backgroundColor = undefined;
    }).catch(async (error) => {
        console.error('Failed to start ARO Language Server:', error);
        console.error('Error details:', JSON.stringify(error, null, 2));

        // Update status: error
        statusBarItem.text = '$(error) ARO LSP: Failed';
        const errorMsg = error.message || String(error);
        statusBarItem.tooltip = `Failed to start: ${errorMsg}. Click to configure.`;
        statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');

        const action = await vscode.window.showErrorMessage(
            `Failed to start ARO Language Server: ${error.message}`,
            'Configure Path',
            'Open Settings',
            'Dismiss'
        );

        if (action === 'Configure Path') {
            await configureLspPath();
        } else if (action === 'Open Settings') {
            await openSettings();
        }
    });

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('aro.restartServer', async () => {
            if (client) {
                statusBarItem.text = '$(sync~spin) ARO LSP: Restarting...';
                statusBarItem.tooltip = 'Restarting ARO Language Server';
                await client.restart();
                statusBarItem.text = '$(check) ARO LSP: Connected';
                statusBarItem.tooltip = 'ARO Language Server is running';
                statusBarItem.backgroundColor = undefined;
                vscode.window.showInformationMessage('ARO Language Server restarted');
            }
        }),
        vscode.commands.registerCommand('aro.openSettings', openSettings),
        vscode.commands.registerCommand('aro.configureLspPath', configureLspPath),
        vscode.commands.registerCommand('aro.debug.start', async () => {
            const folder = vscode.workspace.workspaceFolders?.[0];
            if (!folder) {
                vscode.window.showErrorMessage('Open a workspace folder to debug.');
                return;
            }
            await vscode.debug.startDebugging(folder, {
                type: 'aro',
                request: 'launch',
                name: 'Debug ARO project',
                program: folder.uri.fsPath,
                stopOnEntry: true
            });
        })
    );

    // Register the ARO debug adapter (issue #229 Phase 2 — DAP server)
    context.subscriptions.push(
        vscode.debug.registerDebugAdapterDescriptorFactory('aro', new AroDebugAdapterDescriptorFactory(() => aroPath)),
        vscode.debug.registerDebugConfigurationProvider('aro', new AroDebugConfigurationProvider())
    );

    // Listen for configuration changes
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(async (event) => {
            if (event.affectsConfiguration('aro.lsp')) {
                const action = await vscode.window.showInformationMessage(
                    'ARO Language Server configuration changed. Restart server?',
                    'Restart',
                    'Later'
                );

                if (action === 'Restart' && client) {
                    await client.restart();
                }
            }
        })
    );
}

// Command: Open settings to ARO section
async function openSettings() {
    await vscode.commands.executeCommand(
        'workbench.action.openSettings',
        'aro.lsp'
    );
}

// Command: Interactive path configuration with file picker
async function configureLspPath() {
    const result = await vscode.window.showOpenDialog({
        canSelectFiles: true,
        canSelectFolders: false,
        canSelectMany: false,
        title: 'Select ARO Binary',
        filters: { 'Executable': ['*'] }
    });

    if (result && result[0]) {
        const path = result[0].fsPath;
        const isValid = await validateAroPath(path);

        if (isValid) {
            const config = vscode.workspace.getConfiguration('aro.lsp');
            await config.update('path', path, vscode.ConfigurationTarget.Global);

            vscode.window.showInformationMessage(
                `ARO binary path updated to: ${path}. Restarting server...`
            );

            if (client) {
                await client.restart();
            }
        } else {
            vscode.window.showErrorMessage(
                `Invalid ARO binary at ${path}. Please select a valid ARO executable.`
            );
        }
    }
}

export async function deactivate(): Promise<void> {
    if (client) {
        await client.stop();
    }
}

// ============================================================
// Debugger (issue #229 Phase 2)
// ============================================================

class AroDebugConfigurationProvider implements vscode.DebugConfigurationProvider {
    /**
     * Fill in missing fields when the user picks the "ARO: Launch" template
     * or hits F5 in a file with no launch.json.
     */
    resolveDebugConfiguration(
        folder: vscode.WorkspaceFolder | undefined,
        config: vscode.DebugConfiguration
    ): vscode.ProviderResult<vscode.DebugConfiguration> {
        if (!config.type && !config.request && !config.name) {
            const editor = vscode.window.activeTextEditor;
            if (editor && editor.document.languageId === 'aro') {
                config.type = 'aro';
                config.request = 'launch';
                config.name = 'Debug current ARO file';
                config.program = editor.document.uri.fsPath;
                config.stopOnEntry = true;
            }
        }
        if (!config.program) {
            return vscode.window.showErrorMessage(
                'ARO debugger: specify "program" (a directory or .aro file).'
            ).then(() => undefined);
        }
        if (config.entryPoint == null) config.entryPoint = 'Application-Start';
        if (config.stopOnEntry == null) config.stopOnEntry = true;
        return config;
    }
}

class AroDebugAdapterDescriptorFactory implements vscode.DebugAdapterDescriptorFactory {
    constructor(private readonly aroPath: () => string) {}

    createDebugAdapterDescriptor(
        session: vscode.DebugSession,
        _executable: vscode.DebugAdapterExecutable | undefined
    ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
        const cfg = session.configuration as {
            program?: string;
            entryPoint?: string;
            breakpoint?: string[];
            aroPath?: string;
            dapLog?: string;
        };

        // Per-session override wins over the LSP setting.
        const aroBin = cfg.aroPath || this.aroPath();

        const args: string[] = ['debug', '--dap'];
        if (cfg.entryPoint) {
            args.push('--entry-point', cfg.entryPoint);
        }
        if (cfg.dapLog) {
            args.push('--dap-log', cfg.dapLog);
        }
        for (const bp of cfg.breakpoint || []) {
            args.push('--breakpoint', bp);
        }
        if (cfg.program) {
            args.push(cfg.program);
        }

        return new vscode.DebugAdapterExecutable(aroBin, args, {
            env: { ...process.env, PATH: process.env.PATH + ':/opt/homebrew/bin:/usr/local/bin' }
        });
    }
}
