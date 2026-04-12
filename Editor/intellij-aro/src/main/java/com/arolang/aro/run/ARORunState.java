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
        String command = configuration.getCommandType().getCommand();
        String directory = configuration.getApplicationDirectory();

        GeneralCommandLine commandLine = new GeneralCommandLine()
            .withExePath(aroPath)
            .withParameters(command, directory)
            .withWorkDirectory(directory)
            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE);

        OSProcessHandler handler = ProcessHandlerFactory.getInstance()
            .createColoredProcessHandler(commandLine);
        ProcessTerminatedListener.attach(handler);
        return handler;
    }
}
