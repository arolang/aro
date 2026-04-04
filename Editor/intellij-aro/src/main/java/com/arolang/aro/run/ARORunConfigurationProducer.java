package com.arolang.aro.run;

import com.intellij.execution.actions.ConfigurationContext;
import com.intellij.execution.actions.LazyRunConfigurationProducer;
import com.intellij.execution.configurations.ConfigurationFactory;
import com.intellij.execution.configurations.ConfigurationType;
import com.intellij.execution.configurations.ConfigurationTypeUtil;
import com.intellij.openapi.util.Ref;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiDirectory;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;

import java.io.File;

public class ARORunConfigurationProducer extends LazyRunConfigurationProducer<ARORunConfiguration> {

    @Override
    public @NotNull ConfigurationFactory getConfigurationFactory() {
        ConfigurationType type = ConfigurationTypeUtil.findConfigurationType(ARORunConfigurationType.class);
        return type.getConfigurationFactories()[0];
    }

    @Override
    protected boolean setupConfigurationFromContext(
        @NotNull ARORunConfiguration configuration,
        @NotNull ConfigurationContext context,
        @NotNull Ref<PsiElement> sourceElement
    ) {
        String directory = resolveDirectory(context);
        if (directory == null) return false;

        configuration.setApplicationDirectory(directory);
        configuration.setCommandType(AROCommandType.RUN);
        configuration.setName("ARO: " + new File(directory).getName());
        return true;
    }

    @Override
    public boolean isConfigurationFromContext(
        @NotNull ARORunConfiguration configuration,
        @NotNull ConfigurationContext context
    ) {
        String directory = resolveDirectory(context);
        if (directory == null) return false;
        return directory.equals(configuration.getApplicationDirectory());
    }

    private String resolveDirectory(ConfigurationContext context) {
        PsiElement element = context.getPsiLocation();
        if (element == null) return null;

        // Right-click on a .aro file -> use parent directory
        if (element instanceof PsiFile file) {
            VirtualFile vf = file.getVirtualFile();
            if (vf != null && "aro".equals(vf.getExtension())) {
                return vf.getParent().getPath();
            }
        }

        // Right-click on a directory -> check if it contains .aro files
        if (element instanceof PsiDirectory dir) {
            VirtualFile vf = dir.getVirtualFile();
            if (containsAroFiles(vf)) {
                return vf.getPath();
            }
        }

        // Element inside an .aro file (e.g., cursor in editor)
        PsiFile containingFile = element.getContainingFile();
        if (containingFile != null) {
            VirtualFile vf = containingFile.getVirtualFile();
            if (vf != null && "aro".equals(vf.getExtension())) {
                return vf.getParent().getPath();
            }
        }

        return null;
    }

    private boolean containsAroFiles(VirtualFile dir) {
        if (dir == null || !dir.isDirectory()) return false;
        for (VirtualFile child : dir.getChildren()) {
            if (!child.isDirectory() && "aro".equals(child.getExtension())) {
                return true;
            }
        }
        // Check one level of subdirectories (sources/ convention)
        for (VirtualFile child : dir.getChildren()) {
            if (child.isDirectory()) {
                for (VirtualFile grandchild : child.getChildren()) {
                    if (!grandchild.isDirectory() && "aro".equals(grandchild.getExtension())) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
}
