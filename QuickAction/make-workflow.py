#!/usr/bin/env python3
"""Genera «Cabrio.workflow»: Acción rápida del Finder que abre los archivos o carpetas seleccionados en Cabrio.
Uso: python3 QuickAction/make-workflow.py <document.wflow de plantilla> """
import plistlib, sys, uuid, os, shutil

template = sys.argv[1]
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Cabrio.workflow", "Contents")
shutil.rmtree(os.path.dirname(out), ignore_errors=True)
os.makedirs(out)

doc = plistlib.load(open(template, "rb"))
meta = doc["workflowMetaData"]
for k in ("inputTypeIdentifier", "serviceInputTypeIdentifier"):
    meta[k] = "com.apple.Automator.fileSystemObject"      # archivos y carpetas
action = doc["actions"][0]["action"]
action["ActionParameters"] = {
    # Los archivos llegan como argumentos; `open -b` los entrega a Cabrio aunque no esté abierta.
    "COMMAND_STRING": '/usr/bin/open -b com.chocolitossoft.cabrio "$@"',
    "CheckedForUserDefaultShell": True, "inputMethod": 1, "shell": "/bin/zsh", "source": "",
}
for key in ("InputUUID", "OutputUUID", "UUID"):
    action[key] = str(uuid.uuid4()).upper()
plistlib.dump(doc, open(os.path.join(out, "document.wflow"), "wb"))

info = {"NSServices": [{
    "NSBackgroundColorName": "background", "NSIconName": "NSActionTemplate",
    "NSMenuItem": {"default": "Cabrio"}, "NSMessage": "runWorkflowAsService",
    "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
    "NSSendFileTypes": ["public.item"],
}]}
plistlib.dump(info, open(os.path.join(out, "Info.plist"), "wb"))
print("QuickAction/Cabrio.workflow generado")
