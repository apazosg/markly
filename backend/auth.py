from fastapi import Depends, HTTPException, Header
from firebase_admin import auth


async def verified_user(authorization: str = Header()) -> dict:
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Authorization header must be 'Bearer <token>'")
    token = authorization[7:]
    try:
        return auth.verify_id_token(token)
    except auth.ExpiredIdTokenError:
        raise HTTPException(status_code=401, detail="Token expirado")
    except auth.InvalidIdTokenError:
        raise HTTPException(status_code=401, detail="Token inválido")
    except Exception:
        raise HTTPException(status_code=401, detail="No autenticado")
