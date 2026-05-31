package com.arolang.aro.run;

import com.arolang.aro.AROPathResolver;
import com.intellij.execution.ExecutionException;
import com.intellij.execution.configurations.CommandLineState;
import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.process.OSProcessHandler;
import com.intellij.execution.process.ProcessHandler;
import com.intellij.execution.process.ProcessHandlerFactory;
import com.intellij.execution.process.ProcessTerminatedListener;
import com.intellij.execution.runners.ExecutionEnvironment;
import org.jetbrains.annotations.NotNull;

public class ARORunState extends CommandLineState {

    private final ARORunConfiguration configuration;

    public ARORunState(@NotNull ExecutionEnvironment environment, @NotNull ARORunConfiguration configuration) {
        super(environment);
        this.configuration = configuration;
    }

    @Override
    protected @NotNull ProcessHandler startProcess() throws ExecutionException {
        String aroPath = AROPathResolver.resolve();
        AROCommandType type = configuration.getCommandType();
        String command = type.getCommand();
        String directory = configuration.getApplicationDirectory();

        GeneralCommandLine commandLine = new GeneralCommandLine()
            .withExePath(aroPath)
            .withWorkDirectory(directory)
            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE);

        if (type == AROCommandType.DEBUG) {
            // Issue #229 Phase 2 — `aro debug` exposes both a console TUI
            // and a DAP server. The IntelliJ run-config UI exposes the
            // DAP toggle via ARORunConfigurationOptions.dapMode.
            commandLine.addParameter(command);
            if (configuration.getOptions().getDapMode()) {
                commandLine.addParameter("--dap");
            }
            String bps = configuration.getOptions().getInitialBreakpoints();
            if (bps != null && !bps.isEmpty()) {
                commandLine.addParameter("--breakpoint");
                for (String part : bps.split(",")) {
                    String trimmed = part.trim();
                    if (!trimmed.isEmpty()) {
                        commandLine.addParameter(trimmed);
                    }
                }
            }
            commandLine.addParameter(directory);
        } else {
            commandLine.addParameters(command, directory);
        }

        OSProcessHandler handler = ProcessHandlerFactory.getInstance()
            .createColoredProcessHandler(commandLine);
        ProcessTerminatedListener.attach(handler);
        return handler;
    }
}
