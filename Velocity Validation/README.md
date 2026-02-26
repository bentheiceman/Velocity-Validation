# HD SUPPLY™ VELOCITY VALIDATOR
**Developed by: Ben F. Benjamaa**

A modern, self-contained application for validating velocity codes against Snowflake data with an advanced black and yellow HD Supply™ branded interface.

---

## 🌟 Features

- **Modern Sophisticated GUI** - Sleek 900x750 interface with black background and bright yellow HD Supply™ branding
- **Automated Snowflake SSO** - Secure authentication via external browser
- **Real-Time Progress Tracking** - 10-step visual progress window with status indicators
- **VLOOKUP Functionality** - Automatically matches velocity codes from Snowflake SKUEXTRACT table
- **Data Validation** - Compares Current_Velocity with PROPOSED_VELOCITY
- **DCSKU Column** - Automatic generation by concatenating DC + USN fields
- **Dual-Sheet Excel Export** - Detailed data + Summary statistics
- **Color-Coded Results** - Green for matches, red for mismatches
- **HD Supply™ Formatting** - Professional branded Excel output
- **Self-Contained Executable** - No Python installation required for end users

---

## 📋 Requirements

### For Running the Python Script:
- Python 3.8 or higher
- Required packages (see `requirements.txt`)
- HD Supply email address for Snowflake authentication

### For Using the Executable:
- Windows OS
- HD Supply network access (for Snowflake connection)
- No additional requirements!

---

## 🚀 Quick Start

### Option 1: Run as Python Script

1. **Install Dependencies:**
   ```bash
   Double-click: install_dependencies.bat
   ```
   Or manually:
   ```bash
   pip install -r requirements.txt
   ```

2. **Run the Application:**
   ```bash
   Double-click: run_app.bat
   ```
   Or manually:
   ```bash
   python velocity_validator_app.py
   ```

### Option 2: Build Standalone Executable

1. **Install Dependencies First** (if not already done)

2. **Build Executable:**
   ```bash
   Double-click: build_executable.bat
   ```
   Or manually:
   ```bash
   pyinstaller --clean --onefile velocity_validator.spec
   ```

3. **Use the Executable:**
   - Find it in: `dist\HD_Supply_Velocity_Validator.exe`
   - Double-click to run
   - No Python needed!

---

## 📝 How to Use

### Step 1: Prepare Your Data File
Your Excel/CSV file must contain these columns:
- **JDA_ITEM** (required) - Item identifier
- **JDA_LOC** (required) - Location identifier  
- **PROPOSED_VELOCITY** (required) - Proposed velocity code for comparison
- **DC** (optional) - Distribution center code (for DCSKU generation)
- **USN** (optional) - USN code (for DCSKU generation)

### Step 2: Launch Application
- Run using one of the methods above
- Modern HD Supply™ interface will appear

### Step 3: Select File
- Click **"📂 BROWSE FILE"**
- Select your Excel or CSV file
- File name will display in yellow when selected

### Step 4: Enter Credentials
- **HD Supply Email**: Enter your @hdsupply.com email address
- Authentication will happen automatically via browser (SSO)

### Step 5: Process Data
- Click **"⚡ PROCESS DATA"**
- Progress window shows 10 processing steps:
  1. Connecting to Snowflake
  2. Authenticating user
  3. Fetching velocity data
  4. Loading input file
  5. Validating data structure
  6. Merging datasets
  7. Comparing velocities
  8. Generating Excel report
  9. Applying formatting
  10. Saving output file
- Output file saved in same directory as input file

---

## 📊 Output Format

The application creates an Excel file with **two sheets**:

### Sheet 1: Velocity Validation
**New Columns Added:**
1. **Current_Velocity** - Retrieved from Snowflake `UDC_VELOCITY_CODE`
2. **DCSKU** - Concatenation of DC + USN fields
3. **Match** - True/False comparison with `PROPOSED_VELOCITY`

**Formatting:**
- **Header**: Black background with yellow text (HD Supply™ branding)
- **Current_Velocity Column**: Light yellow background
- **Match Column**: 
  - 🟢 Green background = Match (True)
  - 🔴 Red background = Mismatch (False)

### Sheet 2: Summary
**Statistics Provided:**
- **Total Records** - Total number of items processed
- **Matches** - Count of matching velocity codes
- **Mismatches** - Count of mismatching velocity codes

**Formatting:**
- Professional HD Supply™ branded layout
- Title header with company styling
- Number formatting with thousands separators
- Yellow highlights on statistics

### Output Filename:
```
Velocity_Validated_YYYYMMDD_HHMMSS.xlsx
```

---

## 🗄️ Snowflake Query

The application executes this query against HD Supply's Snowflake database:

```sql
SELECT
    ITEM as JDA_ITEM,
    LOC as JDA_LOC,
    UDC_VELOCITY_CODE
FROM
    EDP.STD_JDA.SKUEXTRACT
```

## 🧮 HDS Velocity Reclassification (SQL)

The Snowflake reclassification logic (including the **New SKU** bucket definition) is maintained in:

- [sql/sku_velocity_reclassification_hds.sql](sql/sku_velocity_reclassification_hds.sql)

**New SKU definition (as of 2026-02-04):** a SKU is classified as **New** only when it has **no first receipt date** (i.e., first receipt is null/missing). SKUs with a valid first receipt date are **Not New**, regardless of how recent the receipt is.

## 🔍 Compare Old vs New Uploads

To request a new round of uploads only for rows that changed between the last request and the new recalculation, you can diff two exported upload files (CSV or XLSX):

```bash
python compare_velocity_uploads.py --old prior_upload.xlsx --new recalculated_upload.xlsx --out delta.csv
```

The `delta.csv` will include:
- rows only present in one file
- rows where the proposed velocity changed for the same `JDA_ITEM` + `JDA_LOC`

**Connection Details:**
- **Account**: HDSUPPLY-DATA
- **Database**: EDP
- **Schema**: STD_JDA
- **Authentication**: External Browser (SSO)

---

## 🎨 Interface Design

**HD Supply™ Color Scheme:**
- Background: Pure Black (`#000000`)
- Primary Text: Bright Yellow (`#FFED4E`)
- Accents: Gold (`#FFD700`)
- Secondary: Dark Gray shades for depth
- Developer Credit: Bottom right corner in italic yellow

**UI Elements:**
- Decorative gold accent lines
- Visual icons throughout (📄📂✉️🔒⚡)
- Bordered frames with subtle highlights
- Large, readable fonts (Segoe UI)
- Custom hover effects on buttons

---

## 📦 File Structure

```
Velocity Validation/
├── velocity_validator_app.py    # Main application with inline documentation
├── requirements.txt              # Python dependencies
├── velocity_validator.spec       # PyInstaller configuration
├── install_dependencies.bat      # Dependency installer
├── run_app.bat                   # Application launcher
├── build_executable.bat          # Executable builder
├── README.md                     # This comprehensive documentation
├── HDP_Velocity_Updated_NEW.csv  # Sample data file
└── dist/                         # Generated executables (after build)
    └── HD_Supply_Velocity_Validator.exe
```

---

## 🔧 Troubleshooting

### Issue: "Module not found" error
**Solution:** Run `install_dependencies.bat` to install all required packages

### Issue: Snowflake connection fails
**Solution:** 
- Verify your HD Supply email address
- Ensure you have network access to Snowflake
- Check that browser opens for SSO authentication
- Ensure you're on HD Supply network or VPN

### Issue: "Column not found" error  
**Solution:** Ensure your input file contains required columns: `JDA_ITEM`, `JDA_LOC`, `PROPOSED_VELOCITY`

### Issue: Executable build fails
**Solution:** 
- Ensure PyInstaller is installed: `pip install pyinstaller`
- Run `pip install -r requirements.txt` first
- Check for antivirus interference

### Issue: Data type mismatch during merge
**Solution:** Application automatically converts columns to string format - this should not occur in current version

---

## 📞 Support

For issues, questions, or feature requests, contact: **Ben F. Benjamaa**

---

## 🔄 Version History

### Version 1.0 (November 2025)
- ✅ Initial release
- ✅ Modern black & yellow HD Supply™ interface (900x750)
- ✅ Automated Snowflake SSO authentication
- ✅ 10-step real-time progress tracking window
- ✅ VLOOKUP functionality with JDA_ITEM/JDA_LOC merge
- ✅ DCSKU column generation (DC + USN concatenation)
- ✅ Dual-sheet Excel export (Data + Summary)
- ✅ Color-coded match/mismatch validation
- ✅ Professional HD Supply™ Excel formatting
- ✅ Comprehensive inline code documentation
- ✅ Standalone executable support
- ✅ Data type conversion for seamless merging
- ✅ Safety checks for missing columns
- ✅ Enhanced error handling

---

## 📄 License

© 2025 HD Supply™ - All Rights Reserved

---

## 🏆 Credits

**HD SUPPLY™ - Velocity Validator**  
*Developed by: Ben F. Benjamaa*

**Technologies Used:**
- Python 3.10+
- Tkinter (GUI Framework)
- Pandas (Data Processing)
- OpenPyXL (Excel Formatting)
- Snowflake Connector (Database Access)
- PyInstaller (Executable Generation)

---

## 🌟 Features

- **Modern GUI** - Sleek black background with bright yellow HD Supply™ branding
- **Snowflake Integration** - Direct connection to Snowflake database
- **VLOOKUP Functionality** - Automatically matches velocity codes from Snowflake
- **Validation** - Compares Current_Velocity with PROPOSED_VELOCITY
- **Excel Export** - Formatted Excel output with color-coded results
- **Real-time Progress** - Visual feedback during processing
- **Self-contained Executable** - No Python installation required for end users

---

## 📋 Requirements

### For Running the Python Script:
- Python 3.8 or higher
- Required packages (see `requirements.txt`)

### For Using the Executable:
- Windows OS
- No additional requirements!

---

## 🚀 Quick Start

### Option 1: Run as Python Script

1. **Install Dependencies:**
   ```bash
   Double-click: install_dependencies.bat
   ```
   Or manually:
   ```bash
   pip install -r requirements.txt
   ```

2. **Run the Application:**
   ```bash
   Double-click: run_app.bat
   ```
   Or manually:
   ```bash
   python velocity_validator_app.py
   ```

### Option 2: Build Standalone Executable

1. **Install Dependencies First** (if not already done)

2. **Build Executable:**
   ```bash
   Double-click: build_executable.bat
   ```
   Or manually:
   ```bash
   pyinstaller --clean --onefile velocity_validator.spec
   ```

3. **Use the Executable:**
   - Find it in: `dist\HD_Supply_Velocity_Validator.exe`
   - Double-click to run
   - No Python needed!

---

## 📝 How to Use

### Step 1: Prepare Your Data File
- Ensure your Excel/CSV file contains columns:
  - `ITEM` (required)
  - `LOC` (required)
  - `PROPOSED_VELOCITY` (required for comparison)

### Step 2: Launch Application
- Run the application using one of the methods above

### Step 3: Select File
- Click **"BROWSE FILE"**
- Select your Excel or CSV file

### Step 4: Enter Snowflake Credentials
- **Account**: Your Snowflake account identifier
- **Username**: Your Snowflake username
- **Password**: Your Snowflake password
- **Warehouse**: Snowflake warehouse name
- **Database**: `EDP` (default)
- **Schema**: `STD_JDA` (default)

### Step 5: Process Data
- Click **"PROCESS DATA"**
- Wait for processing to complete
- Output file will be saved in the same directory as input file

---

## 📊 Output Format

The application creates an Excel file with these additions:

### New Columns:
1. **Current_Velocity** - Retrieved from Snowflake `UDC_VELOCITY_CODE`
2. **Match** - True/False comparison with `PROPOSED_VELOCITY`

### Formatting:
- **Header**: Black background with yellow text (HD Supply™ branding)
- **Current_Velocity Column**: Light yellow background
- **Match Column**: 
  - Green background = Match (True)
  - Red background = Mismatch (False)

### Output Filename:
```
Velocity_Validated_YYYYMMDD_HHMMSS.xlsx
```

---

## 🗄️ Snowflake Query

The application executes this query:

```sql
SELECT
    ITEM,
    LOC,
    UDC_VELOCITY_CODE
FROM
    SKUEXTRACT
```

---

## 🎨 Color Scheme

**HD Supply™ Branding:**
- Background: Pure Black (`#000000`)
- Primary Text: Bright Yellow (`#FFED4E`)
- Accents: Gold (`#FFD700`)
- Highlights: Dark Gray (`#1A1A1A`, `#2D2D2D`)

---

## 📦 File Structure

```
Velocity Validation/
├── velocity_validator_app.py    # Main application
├── requirements.txt              # Python dependencies
├── velocity_validator.spec       # PyInstaller configuration
├── install_dependencies.bat      # Dependency installer
├── run_app.bat                   # Application launcher
├── build_executable.bat          # Executable builder
├── README.md                     # This file
└── dist/                         # Generated executables (after build)
    └── HD_Supply_Velocity_Validator.exe
```

---

## 🔧 Troubleshooting

### Issue: "Module not found" error
**Solution:** Run `install_dependencies.bat` to install all required packages

### Issue: Snowflake connection fails
**Solution:** 
- Verify your credentials
- Ensure you have network access to Snowflake
- Check warehouse, database, and schema names

### Issue: "Column not found" error
**Solution:** Ensure your input file contains required columns: `ITEM`, `LOC`, `PROPOSED_VELOCITY`

### Issue: Executable build fails
**Solution:** 
- Ensure PyInstaller is installed: `pip install pyinstaller`
- Run `pip install -r requirements.txt` first

---

## 📞 Support

For issues or questions, contact: **Ben F. Benjamaa**

---

## 📄 License

© 2025 HD Supply™ - All Rights Reserved

---

## 🔄 Version History

### Version 1.0 (November 2025)
- Initial release
- Modern black & yellow HD Supply™ interface
- Snowflake integration
- VLOOKUP functionality
- Excel export with formatting
- Standalone executable support

---

**HD SUPPLY™ - Velocity Validator**
*Developed by: Ben F. Benjamaa*
