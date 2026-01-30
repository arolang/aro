Dear {{ <user: firstName> }},

Welcome to our service! Your account has been created successfully.

Account Details:
- Email: {{ <user: email> }}
- Plan: {{ <user: plan> }}

{{ <Print> "As a Premium member, you have access to all features!" to the <template> when <user: plan> = "premium". }}
{{ <Print> "Upgrade to Premium to unlock all features!" to the <template> when <user: plan> = "free". }}

Getting Started:
1. Log in to your dashboard
2. Complete your profile
3. Explore our features

If you have any questions, feel free to reach out to our support team.

Best regards,
The Team
