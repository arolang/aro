package com.arolang.aro.run;

import com.intellij.execution.configurations.ConfigurationFactory;
import com.intellij.execution.configurations.ConfigurationType;
import com.intellij.execution.configurations.RunConfiguration;
import com.intellij.icons.AllIcons;
import com.intellij.openapi.project.Project;
import org.jetbrains.annotations.Nls;
import org.jetbrains.annotations.NotNull;

import javax.swing.*;

public class ARORunConfigurationType implements ConfigurationType {

    static final String ID = "ARORunConfiguration";

    @Override
    public @NotNull @Nls String getDisplayName() {
        return "ARO Application";
    }

    @Override
    public @Nls String getConfigurationTypeDescription() {
        return "Run, build, or check an ARO application";
    }

    @Override
    public Icon getIcon() {
        return AllIcons.RunConfigurations.Application;
    }

    @Override
    public @NotNull String getId() {
        return ID;
    }

    @Override
    public ConfigurationFactory[] getConfigurationFactories() {
        return new ConfigurationFactory[]{new Factory(this)};
    }

    private static class Factory extends ConfigurationFactory {

        protected Factory(@NotNull ConfigurationType type) {
            super(type);
        }

        @Override
        public @NotNull String getId() {
            return "ARO Application";
        }

        @Override
        public @NotNull @Nls String getName() {
            return "ARO Application";
        }

        @Override
        public @NotNull RunConfiguration createTemplateConfiguration(@NotNull Project project) {
            return new ARORunConfiguration(project, this, "ARO Application");
        }
    }
}
