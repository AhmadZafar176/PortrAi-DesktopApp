# Fixing Google OAuth 500 Internal Server Error for Multiple Accounts

## Problem
Google Sign-In works for one account but returns a 500 Internal Server Error for all other accounts. This is typically caused by OAuth client restrictions in Google Cloud Console.

## Root Cause
The OAuth client is likely configured in "Testing" mode, which only allows specific test users. When accounts that aren't in the test user list try to sign in, Google returns a 500 error.

## Solution: Update OAuth Client Configuration

### Step 1: Access Google Cloud Console
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Select your project: **ai-booth-edda3**
3. Navigate to **APIs & Services** > **Credentials**

### Step 2: Find Your OAuth Client
1. Look for the OAuth 2.0 Client ID used for Windows:
   - **Client ID**: `955675066153-6prtbeehf3dmqn47ap8ehjv36cbto62v.apps.googleusercontent.com`
   - **Type**: Desktop client

### Step 3: Update OAuth Consent Screen
1. Go to **APIs & Services** > **OAuth consent screen**
2. Check the **Publishing status**:
   - **Testing**: Only test users can sign in (current issue)
   - **In production**: All Google accounts can sign in (recommended)

### Step 4: If Staying in Testing Mode
If you need to keep the app in Testing mode, add all user accounts as test users:

1. In **OAuth consent screen**, scroll to **Test users**
2. Click **+ ADD USERS**
3. Add email addresses of all users who need access
4. Click **SAVE**

### Step 5: If Moving to Production
1. In **OAuth consent screen**, click **PUBLISH APP**
2. Complete any required verification steps
3. Once published, all Google accounts can sign in

## Alternative: Check OAuth Client Restrictions

1. In **Credentials**, click on your OAuth client ID
2. Check for any restrictions:
   - **Application restrictions**: Should be "None" or include your app
   - **Authorized domains**: Should include your domain if set
   - **Authorized redirect URIs**: Should include required URIs

## Verification

After making changes:
1. Wait a few minutes for changes to propagate
2. Try signing in with a previously failing account
3. Check console logs for detailed error messages

## Current OAuth Client IDs

- **Windows Desktop**: `955675066153-6prtbeehf3dmqn47ap8ehjv36cbto62v.apps.googleusercontent.com`
- **Web**: `955675066153-qam0h7sitso8pt7ki7blqu4ucf0jr3ea.apps.googleusercontent.com`

## Notes

- Changes to OAuth consent screen can take a few minutes to propagate
- If the app is in Testing mode, you must add each user as a test user
- For production apps, consider verifying your app with Google for better user experience
- The working account is likely the owner/developer account or a test user already configured

