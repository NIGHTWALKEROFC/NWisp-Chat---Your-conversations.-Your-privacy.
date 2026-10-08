package com.nightwalker.securechat

import androidx.core.content.FileProvider

/// Hands the downloaded update file to Android's installer (see
/// res/xml/nwisp_update_paths.xml). It is its own small class so it never
/// clashes with the file providers other libraries add.
class UpdateFileProvider : FileProvider()
