import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
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

    // Server options - run the ARO language server
    const serverOptions: ServerOptions = {
        command: aroPath,
        args: debug ? ['lsp', '--debug'] : ['lsp'],
        transport: TransportKind.stdio
    };

    // Client options
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'aro' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.aro')
        },
        outputChannelName: 'ARO Language Server'
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

        // Update status: error
        statusBarItem.text = '$(error) ARO LSP: Failed';
        statusBarItem.tooltip = `Failed to start: ${error.message}. Click to configure.`;
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
        vscode.commands.registerCommand('aro.configureLspPath', configureLspPath)
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
