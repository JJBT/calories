# Calories App

A modern iOS calorie tracker focused on **fast food logging** with chat, photos, and voice.

Built with **SwiftUI**.

---

## ✨ What this app does

- Track daily calories and macros (Protein / Fat / Carbs)
- Log meals through an AI chat flow
- Add food using:
  - text
  - voice (transcription)
  - photos
- Confirm registration before saving to your daily log
- Browse and reuse meals via:
  - **Recent** (last 4 weeks, de-duplicated)
  - **Favorites**
- Edit favorites and propagate updates to matching logged entries
- Quick “add again” flows for editable days

---

## 🧱 Tech stack

- **SwiftUI** (iOS 17+)
- OpenAI Responses API (multimodal)
- OpenAI Audio Transcriptions (Whisper)
- Local persistence (JSON stores in Application Support)
- Supabase-ready backend plan (Auth + Postgres + RLS)

---

## 🚀 Getting started

### 1) Open project

Open:

- `CaloriesApp/Calories.xcodeproj`

Scheme:

- `Calories`

### 2) Configure API keys

Create (or update) `CaloriesApp/Config.xcconfig`:

```xcconfig
OPENAI_API_KEY = sk-...
OPENAI_MODEL = gpt-5.2
OPENAI_TRANSCRIBE_MODEL = whisper-1
SUPABASE_URL = https\://YOUR_PROJECT.supabase.co
SUPABASE_PUBLISHABLE_KEY = YOUR_ANON_OR_PUBLISHABLE_KEY
SUPABASE_REDIRECT_URL = calories://auth-callback
```

Make sure `Config.xcconfig` is applied to your build configuration.

### 3) Run

- Select an iOS Simulator or device
- Build and run from Xcode

---

## 📱 Main UX areas

### Home ("Logged")
- Daily macro/goal progress
- Logged meals list with context actions
- Edit/delete entries
- Add-again actions for editable days

### Add Food flow
- Chat-based meal registration
- Draft media strip with quick image editing (rotate/crop)
- Registration confirmation + toast feedback

### Recent
- Entries from the last 28 days
- Search
- Add to selected day (today / yesterday / 2 days ago)
- Add to favorites

### Favorites
- Search
- Add to selected day
- Edit favorite nutrition values
- Remove from favorites

---

## 🔐 Backend direction (in progress)

Planned backend is **Supabase** with:

- Auth (Apple / Email)
- Postgres tables (`profiles`, `food_entries`, `favorites`)
- Row Level Security (user can only access own data)
- Guest mode fallback (local-only when unauthenticated)

---

## ⚠️ Notes

- Current app is actively evolving; UX and flows are being refined quickly.
- Keep secrets (`OPENAI_API_KEY`) out of git.
- For production, use a secure backend/proxy strategy for model access.

---

## 📄 License

Private/internal project (for now).
