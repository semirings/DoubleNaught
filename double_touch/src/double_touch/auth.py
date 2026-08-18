from google_auth_oauthlib.flow import InstalledAppFlow

# Define the scopes your application needs
SCOPES = ['https://www.googleapis.com/auth/userinfo.profile', 'openid']

def authenticate_user():
    # Load client secrets from your config directory
    flow = InstalledAppFlow.from_client_secrets_file(
        'config/client_secret.json', 
        scopes=SCOPES
    )

    # Runs a local web server to capture the OAuth redirect on Desktop
    credentials = flow.run_local_server(port=0)
    print("Authentication successful!")
    return credentials

if __name__ == "__main__":
    authenticate_user()