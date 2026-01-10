package com.arolang.aro;

import com.intellij.codeInsight.template.TemplateActionContext;
import com.intellij.codeInsight.template.TemplateContextType;
import org.jetbrains.annotations.NotNull;

/**
 * Template context type for ARO live templates.
 * Enables live templates in .aro files.
 */
public class AROTemplateContextType extends TemplateContextType {

    protected AROTemplateContextType() {
        super("ARO", "ARO");
    }

    @Override
    public boolean isInContext(@NotNull TemplateActionContext templateActionContext) {
        String fileName = templateActionContext.getFile().getName();
        return fileName.endsWith(".aro");
    }
}
