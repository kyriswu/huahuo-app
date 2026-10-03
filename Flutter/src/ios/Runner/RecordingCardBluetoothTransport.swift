import CoreBluetooth

#if DEBUG && targetEnvironment(simulator)
typealias RecordingCardCentral = SimulatorBleCentral
typealias RecordingCardPeripheral = SimulatorBlePeripheral
typealias RecordingCardService = SimulatorBleService
typealias RecordingCardCharacteristic = SimulatorBleCharacteristic
typealias RecordingCardCentralDelegate = SimulatorBleCentralDelegate
typealias RecordingCardPeripheralDelegate = SimulatorBlePeripheralDelegate
#else
// These are aliases, not wrappers: iPhone keeps the system implementation.
typealias RecordingCardCentral = CBCentralManager
typealias RecordingCardPeripheral = CBPeripheral
typealias RecordingCardService = CBService
typealias RecordingCardCharacteristic = CBCharacteristic
typealias RecordingCardCentralDelegate = CBCentralManagerDelegate
typealias RecordingCardPeripheralDelegate = CBPeripheralDelegate
#endif
