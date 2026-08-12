-- Contact photos pushed by the Mac agent (CNContactStore thumbnails).
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS contact_photo_url TEXT;
