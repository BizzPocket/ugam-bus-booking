# Appwrite Collection Setup via CSV Import

Use these CSV files to bootstrap the 3 collections needed by TourPro.

## How to import

1. Open your Appwrite console → Databases → your database (`69e5ea7b000f6b95e6e9`)
2. Click **Create collection**
3. In the creation dialog, use the **Import from CSV** option (if available in your Appwrite version)
4. Upload the corresponding CSV file
5. Appwrite will auto-detect column types from the sample data
6. **Name the collection** exactly as shown below (the collection ID matters — it must match the app config)

## Collections to create

| CSV File | Collection Name | Collection ID to set |
|---|---|---|
| `tours.csv` | Tours | `tours` (or keep the one already created: `69e5eaa9003cf0176299`) |
| `passengers.csv` | Passengers | `passengers` |
| `bus_details.csv` | Bus Details | `busDetails` |

> **Important**: If Appwrite auto-generates a random Collection ID, either:
> - Change it to the name above during creation, OR
> - Send me the random IDs and I'll update `lib/config/appwrite_config.dart`.

## Post-import steps (manual tweaks needed)

### 1. Set permissions on each collection
Go to each collection → **Settings** → **Permissions** → Add role `Any` with:
- ✅ Create
- ✅ Read
- ✅ Update
- ✅ Delete (**don't forget this one**)

### 2. Add `assignedSeats` array attribute to `passengers`
CSV import can't create array-type attributes. After importing `passengers.csv`:
- Go to `passengers` collection → **Attributes** → **Create attribute**
- Type: **String**
- Attribute Key: `assignedSeats`
- Size: 10
- **Array: enabled (toggle on)**
- Required: ❌
- Default: leave empty

### 3. Verify `createdBy` in `tours` is String (not Datetime)
If Appwrite auto-detected `createdBy` as Datetime, delete and recreate as:
- Type: **String**, Size: 50, Required: ❌

### 4. (Optional) Make required fields required
CSV import creates all attributes as optional. If you want to enforce required fields as listed in the app schema, edit each attribute and toggle **Required: Yes** for:
- **tours**: `title`, `fromCity`, `toCity`, `departureDate`, `pricePerSeat`, `status`
- **passengers**: `tourId`, `name`, `phone`, `requestedSeats`, `seatPreference`, `ageGroup`, `paymentStatus`, `isHandler`
- **busDetails**: `tourId`, `busNumber`, `driverName`, `driverPhone`, `isAC`, `busType`, `totalSeats`

### 5. (Optional) Delete sample rows
The CSVs include sample rows so Appwrite can infer attribute types. You can delete these sample documents from each collection after import.

## Expected column types (for manual creation if CSV import unavailable)

### tours
| Key | Type | Size |
|---|---|---|
| title | String | 255 |
| fromCity | String | 100 |
| toCity | String | 100 |
| departureDate | Datetime | — |
| returnDate | Datetime | — |
| pricePerSeat | Float | — |
| description | String | 1000 |
| status | String | 50 |
| handlerId | String | 50 |
| createdBy | String | 50 |

### passengers
| Key | Type | Size | Array |
|---|---|---|---|
| tourId | String | 50 | — |
| userId | String | 50 | — |
| name | String | 255 | — |
| phone | String | 20 | — |
| requestedSeats | Integer | — | — |
| seatPreference | String | 30 | — |
| ageGroup | String | 30 | — |
| assignedSeats | String | 10 | ✅ Yes |
| paymentStatus | String | 20 | — |
| isHandler | Boolean | — | — |

### busDetails
| Key | Type | Size |
|---|---|---|
| tourId | String | 50 |
| busNumber | String | 50 |
| driverName | String | 100 |
| driverPhone | String | 20 |
| ownerName | String | 100 |
| ownerPhone | String | 20 |
| isAC | Boolean | — |
| busType | String | 50 |
| totalSeats | Integer | — |
| notes | String | 500 |
