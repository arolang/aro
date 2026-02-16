package com.arolang.aro;

import com.intellij.spellchecker.BundledDictionaryProvider;
import org.jetbrains.annotations.NotNull;

/**
 * Provides a bundled dictionary for ARO-specific terms.
 * This prevents spell check warnings for valid ARO keywords.
 */
public class AROSpellCheckerDictionary implements BundledDictionaryProvider {
    @NotNull
    @Override
    public String[] getBundledDictionaries() {
        return new String[]{"/dictionaries/aro.dic"};
    }
}
