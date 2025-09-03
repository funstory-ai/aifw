import os
import re
from datetime import datetime
from typing import Optional


def cleanup_monthly_logs(base_path: Optional[str], months_to_keep: Optional[int]) -> None:
    """Delete monthly-rotated logs older than months_to_keep.

    base_path: The base log path before monthly suffix, e.g., /var/log/aifw/server.log
    months_to_keep: Number of months to retain. 0 => never clean. None/negative => default 6.
    """
    if not base_path:
        return
    try:
        keep = 6 if (months_to_keep is None or months_to_keep < 0) else months_to_keep
        if keep == 0:
            return
        base_path = os.path.expanduser(base_path)
        base_dir = os.path.dirname(base_path)
        file_name = os.path.basename(base_path)
        if not base_dir:
            base_dir = "."
        if file_name.endswith('.log'):
            stem = re.escape(file_name[:-4])
            pattern = re.compile(rf"^{stem}-([0-9]{{4}})-([0-9]{{2}})\.log$")
        else:
            stem = re.escape(file_name)
            pattern = re.compile(rf"^{stem}-([0-9]{{4}})-([0-9]{{2}})$")
        try:
            entries = os.listdir(base_dir)
        except Exception:
            return
        now = datetime.now()
        for entry in entries:
            m = pattern.match(entry)
            if not m:
                continue
            try:
                year = int(m.group(1))
                month = int(m.group(2))
            except Exception:
                continue
            age_months = (now.year - year) * 12 + (now.month - month)
            if age_months >= keep:
                try:
                    os.remove(os.path.join(base_dir, entry))
                except Exception:
                    pass
    except Exception:
        # Best-effort cleanup; do not raise
        pass


