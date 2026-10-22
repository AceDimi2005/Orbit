"""Small adapters for Windows' internal audio policy interfaces.

AudioPolicyConfig sets one application's output preference. Microsoft documents
WinRT activation/HSTRING and Core Audio endpoint IDs, but not this internal policy
interface. Its two exact interface GUIDs and complete IInspectable slot layout are
verified against EarTrumpet's original definitions:
https://github.com/File-New-Project/EarTrumpet/tree/master/EarTrumpet/Interop/MMDeviceAPI
Per-app routing never falls back to changing the system default device.

DefaultEndpointPolicy changes the system default device itself, only when the owner
asks for exactly that (POST /api/audio/default). It uses IPolicyConfig, created from
CLSID PolicyConfigClient and queried for the one IID whose layout is verified against
EarTrumpet's IPolicyConfigWin7 (IPolicyConfig.cs, PolicyConfigClient.cs). See
THIRD_PARTY_NOTICES.md.
"""
import ctypes
import os
import sys
import uuid


class AudioPolicyUnavailable(RuntimeError):
    pass


class _GUID(ctypes.Structure):
    _fields_ = [("data1", ctypes.c_uint32), ("data2", ctypes.c_uint16),
                ("data3", ctypes.c_uint16), ("data4", ctypes.c_ubyte * 8)]

    @classmethod
    def parse(cls, text):
        return cls.from_buffer_copy(uuid.UUID(text).bytes_le)


class AudioPolicyConfig:
    # IUnknown (3) + IInspectable (3) + 19 preceding methods = slot 25.
    INTERFACES = ("ab3d4648-e242-459f-b02f-541c70306324",  # Windows 11 21H2+
                  "2a59116d-6c4f-45e0-a74f-707e3fef9258")  # Windows 10
    SET_SLOT = 25
    GET_SLOT = 26
    PREFIX = "\\\\?\\SWD#MMDEVAPI#"
    SUFFIX = "#{e6327cad-dcec-4949-ae8a-991e976a79d2}"

    def __init__(self):
        self.factory = ctypes.c_void_p()
        self.initialized = False
        if os.name != "nt" or sys.getwindowsversion().major != 10 or sys.getwindowsversion().build < 19041:
            raise AudioPolicyUnavailable("Per-app output routing requires Windows 10 version 2004 or later, or Windows 11.")
        self.api = ctypes.WinDLL("combase", use_last_error=True)
        definitions = (
            ("RoInitialize", [ctypes.c_uint32], ctypes.c_int32),
            ("RoUninitialize", [], None),
            ("WindowsCreateString", [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
            ("WindowsDeleteString", [ctypes.c_void_p], ctypes.c_int32),
            ("WindowsGetStringRawBuffer", [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)], ctypes.c_void_p),
            ("RoGetActivationFactory", [ctypes.c_void_p, ctypes.POINTER(_GUID), ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
        )
        for name, arguments, result in definitions:
            function = getattr(self.api, name); function.argtypes = arguments; function.restype = result
        # FastAPI's audio request already uses an STA COM apartment. Balance
        # every successful RoInitialize (including S_FALSE) on this same thread.
        if self.api.RoInitialize(0) < 0:
            raise AudioPolicyUnavailable("Windows could not initialize per-app audio policy on this request thread.")
        self.initialized = True
        name = ctypes.c_void_p()
        try:
            name = self._string("Windows.Media.Internal.AudioPolicyConfig")
            for interface in self.INTERFACES:
                identity = _GUID.parse(interface)
                if self.api.RoGetActivationFactory(name, ctypes.byref(identity), ctypes.byref(self.factory)) >= 0 and self.factory:
                    break
            if not self.factory:
                raise AudioPolicyUnavailable("This Windows version does not expose a supported per-app audio policy interface. Use Windows Settings → System → Sound → Volume mixer.")
        except Exception:
            self.close()
            raise
        finally:
            if name:
                self.api.WindowsDeleteString(name)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _method(self, slot, *arguments):
        # Querying a known IID above is mandatory before any ABI slot call.
        table = ctypes.cast(self.factory, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        return ctypes.WINFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, *arguments)(table[slot])

    def _string(self, text):
        result = ctypes.c_void_p()
        if self.api.WindowsCreateString(text, len(text.encode("utf-16-le")) // 2, ctypes.byref(result)) < 0:
            raise AudioPolicyUnavailable("Windows could not allocate an audio endpoint string.")
        return result

    def close(self):
        try:
            if self.factory:
                self._method(2)(self.factory)  # IUnknown::Release
                self.factory = ctypes.c_void_p()
        finally:
            if self.initialized:
                self.api.RoUninitialize(); self.initialized = False

    @classmethod
    def unpack(cls, endpoint):
        if endpoint.startswith(cls.PREFIX):
            endpoint = endpoint[len(cls.PREFIX):]
        if endpoint.casefold().endswith(cls.SUFFIX):
            endpoint = endpoint[:-len(cls.SUFFIX)]
        return endpoint

    def _get_raw(self, pid, role):
        result = ctypes.c_void_p()
        method = self._method(self.GET_SLOT, ctypes.c_uint32, ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p))
        status = method(self.factory, pid, 0, role, ctypes.byref(result))
        if status & 0xFFFFFFFF == 0x80070490:  # HRESULT_FROM_WIN32(ERROR_NOT_FOUND)
            return ""  # No per-app override means System default.
        if status < 0:
            raise AudioPolicyUnavailable("Windows could not read this application's output preference.")
        try:
            length = ctypes.c_uint32()
            pointer = self.api.WindowsGetStringRawBuffer(result, ctypes.byref(length))
            if length.value > 32768:
                raise AudioPolicyUnavailable("Windows returned an invalid audio endpoint preference.")
            return ctypes.wstring_at(pointer, length.value) if pointer and length.value else ""
        finally:
            if result:
                self.api.WindowsDeleteString(result)

    def _set_raw(self, pid, role, endpoint):
        value = self._string(endpoint) if endpoint else ctypes.c_void_p()
        try:
            method = self._method(self.SET_SLOT, ctypes.c_uint32, ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p)
            if method(self.factory, pid, 0, role, value) < 0:
                raise AudioPolicyUnavailable("Windows rejected this application's output preference. Its audio device may have disconnected.")
        finally:
            if value:
                self.api.WindowsDeleteString(value)

    def set_output(self, pid, endpoint, verify):
        """Set this PID's render preference only, preserving each role on failure.

        Some apps ignore Windows preferences or recreate streams only when
        playback restarts. The caller must not claim immediate audio migration.
        """
        packed = self.PREFIX + endpoint + self.SUFFIX if endpoint else ""
        verify()
        previous = {role: self._get_raw(pid, role) for role in (0, 1, 2)}
        changed = []
        try:
            for role in (0, 1, 2):  # console, multimedia, communications
                verify()
                self._set_raw(pid, role, packed)
                changed.append(role)
                if self.unpack(self._get_raw(pid, role)).casefold() != endpoint.casefold():
                    raise AudioPolicyUnavailable("Windows did not retain the requested application output preference.")
        except Exception:
            for role in reversed(changed):
                try:
                    verify()  # Never restore a preference onto a reused PID.
                    self._set_raw(pid, role, previous[role])
                except Exception:
                    pass
            raise


class DefaultEndpointPolicy:
    """IPolicyConfig::SetDefaultEndpoint for the console, multimedia and communications roles.

    CoCreateInstance asks for the verified IID directly: Windows 10 TH1/TH2 used other
    IIDs, and an unknown layout is refused before any slot is called.
    """
    CLSID = "870af99c-171d-4f9e-af0d-e63df40c2bc9"  # PolicyConfigClient
    IID = "f8679f50-850a-41cf-9c72-430f290290c8"    # IPolicyConfig (Windows 7, 8, 10 RS1+, 11)
    # IUnknown (3) + Unused1-8 (8) + GetPropertyValue + SetPropertyValue = slot 13.
    SET_DEFAULT_SLOT = 13
    ROLES = (0, 1, 2)  # eConsole, eMultimedia, eCommunications

    def __init__(self, api=None):
        self.client = ctypes.c_void_p()
        if os.name != "nt" and api is None:
            raise AudioPolicyUnavailable("Changing the default audio device requires Windows.")
        self.api = api or ctypes.WinDLL("ole32", use_last_error=True)
        self.api.CoCreateInstance.argtypes = [ctypes.POINTER(_GUID), ctypes.c_void_p, ctypes.c_uint32,
                                              ctypes.POINTER(_GUID), ctypes.POINTER(ctypes.c_void_p)]
        self.api.CoCreateInstance.restype = ctypes.c_int32
        clsid, iid = _GUID.parse(self.CLSID), _GUID.parse(self.IID)
        status = self.api.CoCreateInstance(ctypes.byref(clsid), None, 0x17, ctypes.byref(iid), ctypes.byref(self.client))
        if status < 0 or not self.client:
            self.client = ctypes.c_void_p()
            raise AudioPolicyUnavailable("This Windows version does not let Orbit change the default audio device. "
                                         "Use Windows Settings → System → Sound.")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _method(self, slot, *arguments):
        table = ctypes.cast(self.client, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        prototype = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)
        return prototype(ctypes.c_int32, ctypes.c_void_p, *arguments)(table[slot])

    def set_default(self, device_id, roles=ROLES):
        if not isinstance(device_id, str) or not device_id or len(device_id) > 32768 or "\0" in device_id:
            raise AudioPolicyUnavailable("Select an active audio device.")
        method = self._method(self.SET_DEFAULT_SLOT, ctypes.c_wchar_p, ctypes.c_int32)
        for role in roles:
            if method(self.client, device_id, role) < 0:
                raise AudioPolicyUnavailable("Windows refused to make this the default audio device. It may have disconnected.")

    def close(self):
        if self.client:
            try:
                self._method(2)(self.client)  # IUnknown::Release
            finally:
                self.client = ctypes.c_void_p()
