package com.arolang.aro.run;

import com.intellij.execution.Executor;
import com.intellij.execution.configurations.*;
import com.intellij.execution.runners.ExecutionEnvironment;
import com.intellij.openapi.options.SettingsEditor;
import com.intellij.openapi.project.Project;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.io.File;

public class ARORunConfiguration extends RunConfigurationBase<ARORunConfigurationOptions> {

    protected ARORunConfiguration(@NotNull Project project, @NotNull ConfigurationFactory factory, @Nullable String name) {
        super(project, factory, name);
    }

    @Override
    protected @NotNull ARORunConfigurationOptions getOptions() {
        return (ARORunConfigurationOptions) super.getOptions();
    }

    public AROCommandType getCommandType() {
        return AROCommandType.fromCommand(getOptions().getCommandType());
    }

    public void setCommandType(AROCommandType type) {
        getOptions().setCommandType(type.getCommand());
    }

    public String getApplicationDirectory() {
        return getOptions().getApplicationDirectory();
    }

    public void setApplicationDirectory(String path) {
        getOptions().setApplicationDirectory(path);
    }

    @Override
    public @NotNull SettingsEditor<? extends RunConfiguration> getConfigurationEditor() {
        return new ARORunConfigurationEditor(getProject());
    }

    @Override
    public void checkConfiguration() throws RuntimeConfigurationException {
        String dir = getApplicationDirectory();
        if (dir == null || dir.isEmpty()) {
            throw new RuntimeConfigurationError("Application directory is not specified");
        }
        File file = new File(dir);
        if (!file.exists() || !file.isDirectory()) {
            throw new RuntimeConfigurationError("Application directory does not exist: " + dir);
        }
        // Check for .aro files
        File[] aroFiles = file.listFiles((d, name) -> name.endsWith(".aro"));
        if (aroFiles == null || aroFiles.length == 0) {
            // Also check subdirectories (sources/ convention)
            boolean found = hasAroFilesRecursive(file, 3);
            if (!found) {
                throw new RuntimeConfigurationWarning("No .aro files found in: " + dir);
            }
        }
    }

    private boolean hasAroFilesRecursive(File dir, int maxDepth) {
        if (maxDepth <= 0) return false;
        File[] files = dir.listFiles();
        if (files == null) return false;
        for (File f : files) {
            if (f.isFile() && f.getName().endsWith(".aro")) return true;
            if (f.isDirectory() && hasAroFilesRecursive(f, maxDepth - 1)) return true;
        }
        return false;
    }

    @Override
    public @Nullable RunProfileState getState(@NotNull Executor executor, @NotNull ExecutionEnvironment environment) {
        return new ARORunState(environment, this);
    }
}
