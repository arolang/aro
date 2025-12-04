package com.krissimon.aro;

import org.jetbrains.annotations.NotNull;
import org.jetbrains.plugins.textmate.api.TextMateBundleProvider;

import java.io.InputStream;

/**
 * Provides the TextMate grammar bundle for ARO syntax highlighting.
 */
public class AROTextMateBundleProvider implements TextMateBundleProvider {

    @Override
    public @NotNull InputStream getBundle() {
        InputStream stream = getClass().getResourceAsStream("/textmate/aro.tmLanguage.json");
        if (stream == null) {
            throw new IllegalStateException("ARO TextMate grammar not found");
        }
        return stream;
    }

    @Override
    public @NotNull String getBundleName() {
        return "ARO";
    }
}
