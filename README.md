# Calories

A chill(vibe)-coded iOS app for fast calorie and macro tracking.

Log meals with **text, voice, or photos**, get AI nutrition estimates, and save entries in a clean daily flow.

---

## Features

- Daily calories + macros tracking (**Protein / Fat / Carbs**)
- AI chat for meal parsing and nutrition estimation
- Multimodal input:
  - Text
  - Voice (speech-to-text)
  - Images
- Confirmation step before registration
- Reuse flow for faster logging:
  - **Recent** (last 4 weeks)
  - **Favorites**
- Edit or remove saved/favorite items

---

## Tech Stack

- **SwiftUI** (iOS 17+)
- OpenAI Responses API
- OpenAI Transcriptions (Whisper)
- Local persistence (JSON in Application Support)
- Supabase integration path (Auth + DB)

---

## Project Structure

- `CaloriesApp/` — Xcode project and app sources
- `CaloriesApp/Sources/Calories/` — core app code
- `CaloriesApp/Config.xcconfig.example` — safe config template (no secrets)
