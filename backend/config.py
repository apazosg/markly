from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str
    firebase_sa_json: str = ""
    upload_dir: str = "/app/data"
    deepgram_api_key: str
    gemini_api_key: str = ""

    # Tasas de coste real (EUR) — ajustar si cambian los modelos
    deepgram_rate_eur_per_min: float = 0.0044   # Whisper Large ~$0.0048/min
    gemini_input_rate_eur_per_1m: float = 0.14  # Gemini 2.5 Flash input
    gemini_output_rate_eur_per_1m: float = 0.55  # Gemini 2.5 Flash output
    credit_markup: float = 227.0                 # coste real × markup = créditos; 1 cr ≈ 1 min
    free_credits_per_month: float = 30.0         # créditos gratuitos al mes por usuario
    unlimited_emails: str = ""                   # CSV de emails sin límite de créditos (ej: admin@x.com,dev@x.com)

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
