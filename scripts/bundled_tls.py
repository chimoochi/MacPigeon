"""TLS trust from the shipped CA bundle, independent of the build machine."""
import ssl
import sys
from pathlib import Path

vendor = Path(__file__).resolve().parent / 'python-vendor'
if vendor.is_dir():
    sys.path.insert(0, str(vendor))
import certifi
import anisette


def create_context():
    context = ssl.create_default_context(cafile=certifi.where())
    # Apple provisioning also uses its private service certificate chain.
    context.load_verify_locations(cafile=str(Path(anisette.__file__).parent / "apple-root.pem"))
    return context
