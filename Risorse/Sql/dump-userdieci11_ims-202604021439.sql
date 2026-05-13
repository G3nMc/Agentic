-- MySQL dump 10.13  Distrib 8.0.19, for Win64 (x86_64)
--
-- Host: ims.helioho.st    Database: userdieci11_ims
-- ------------------------------------------------------
-- Server version	5.5.5-10.5.29-MariaDB-log

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `ateco_code`
--

DROP TABLE IF EXISTS `ateco_code`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ateco_code` (
  `ATECO_CODE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del codice ATECO',
  `CODE` char(6) NOT NULL COMMENT 'Codice attivita ATECO 2007 (es. 62.01)',
  `DESCRIPTION` varchar(250) NOT NULL COMMENT 'Descrizione dell attivita economica',
  `TAXABLE_INCOME_PERCENT` decimal(5,2) unsigned NOT NULL DEFAULT 0.00 COMMENT 'Regime forfettario: percentuale di deduzione forfettaria sul reddito imponibile per questa attivita',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 codice obsoleto',
  PRIMARY KEY (`ATECO_CODE_ID`),
  UNIQUE KEY `UQ_ATECO_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Codici attivita ATECO 2007 per classificazione attivita del cedente';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `ateco_code`
--

LOCK TABLES `ateco_code` WRITE;
/*!40000 ALTER TABLE `ateco_code` DISABLE KEYS */;
/*!40000 ALTER TABLE `ateco_code` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `customer`
--

DROP TABLE IF EXISTS `customer`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `customer` (
  `CUSTOMER_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del cliente',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente proprietario di questo cliente',
  `SUBJECT_TYPE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso subject_type - persona fisica (PF) o persona giuridica (PG)',
  `IDENTIFICATION_NATION_ID` int(10) unsigned NOT NULL COMMENT 'FK verso nation - paese di identificazione fiscale del cliente',
  `PRICE_LIST_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso price_list - listino prezzi assegnato al cliente, NULL usa il listino predefinito del cedente',
  `AGENT_USER_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso user - agente commerciale assegnato a questo cliente',
  `BUSINESS_NAME` varchar(80) DEFAULT NULL COMMENT 'Ragione sociale per persone giuridiche (PG)',
  `TITLE` varchar(10) DEFAULT NULL COMMENT 'Titolo (es. Sig., Dott.) per persone fisiche (PF)',
  `FIRST_NAME` varchar(60) DEFAULT NULL COMMENT 'Nome - utilizzato per persone fisiche (PF)',
  `LAST_NAME` varchar(60) DEFAULT NULL COMMENT 'Cognome - utilizzato per persone fisiche (PF)',
  `VAT_NUMBER` varchar(30) DEFAULT NULL COMMENT 'Partita IVA - fino a 30 caratteri per supportare formati esteri',
  `TAX_CODE` varchar(16) DEFAULT NULL COMMENT 'Codice fiscale italiano - 16 caratteri alfanumerici',
  `EORI_CODE` varchar(17) DEFAULT NULL COMMENT 'Codice EORI per identificazione doganale in ambito import/export',
  `EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email principale di contatto del cliente',
  `PHONE` varchar(20) DEFAULT NULL COMMENT 'Numero di telefono principale del cliente con prefisso internazionale',
  `MOBILE` varchar(20) DEFAULT NULL COMMENT 'Numero di cellulare del cliente con prefisso internazionale',
  `FAX` varchar(20) DEFAULT NULL COMMENT 'Numero di fax del cliente',
  `WEBSITE` varchar(255) DEFAULT NULL COMMENT 'URL del sito web del cliente',
  `EXTERNAL_CODE` varchar(50) DEFAULT NULL COMMENT 'Codice cliente esterno o codice importato da altro gestionale',
  `DEFAULT_PAYMENT_MODE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso payment_mode - modalita di pagamento predefinita per questo cliente',
  `NOTE` text DEFAULT NULL COMMENT 'Note interne sul cliente - non stampate sui documenti',
  `IS_PA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il cliente e una Pubblica Amministrazione',
  `IS_STAMP_RIVALSA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il bollo in rivalsa deve essere applicato ai documenti verso questo cliente',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato o cancellato logicamente',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`CUSTOMER_ID`),
  UNIQUE KEY `UQ_CUSTOMER_ISSUER_VAT` (`ISSUER_ID`,`VAT_NUMBER`),
  UNIQUE KEY `UQ_CUSTOMER_ISSUER_TAX_CODE` (`ISSUER_ID`,`TAX_CODE`),
  UNIQUE KEY `UQ_CUSTOMER_ISSUER_EXT_CODE` (`ISSUER_ID`,`EXTERNAL_CODE`),
  KEY `IDX_CUSTOMER_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_CUSTOMER_SUBJECT_TYPE_ID` (`SUBJECT_TYPE_ID`),
  KEY `IDX_CUSTOMER_IDENTIFICATION_NATION_ID` (`IDENTIFICATION_NATION_ID`),
  KEY `IDX_CUSTOMER_PRICE_LIST_ID` (`PRICE_LIST_ID`),
  KEY `IDX_CUSTOMER_AGENT_USER_ID` (`AGENT_USER_ID`),
  KEY `IDX_CUSTOMER_PAYMENT_MODE_ID` (`DEFAULT_PAYMENT_MODE_ID`),
  KEY `IDX_CUSTOMER_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_CUSTOMER_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_CUSTOMER_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_CUSTOMER_AGENT_USER_ID` FOREIGN KEY (`AGENT_USER_ID`) REFERENCES `user` (`USER_ID`) ON DELETE SET NULL,
  CONSTRAINT `FK_CUSTOMER_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_CUSTOMER_IDENTIFICATION_NATION_ID` FOREIGN KEY (`IDENTIFICATION_NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_CUSTOMER_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`),
  CONSTRAINT `FK_CUSTOMER_PAYMENT_MODE_ID` FOREIGN KEY (`DEFAULT_PAYMENT_MODE_ID`) REFERENCES `payment_mode` (`PAYMENT_MODE_ID`),
  CONSTRAINT `FK_CUSTOMER_PRICE_LIST_ID` FOREIGN KEY (`PRICE_LIST_ID`) REFERENCES `price_list` (`PRICE_LIST_ID`) ON DELETE SET NULL,
  CONSTRAINT `FK_CUSTOMER_SUBJECT_TYPE_ID` FOREIGN KEY (`SUBJECT_TYPE_ID`) REFERENCES `subject_type` (`SUBJECT_TYPE_ID`),
  CONSTRAINT `FK_CUSTOMER_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica clienti per cedente - identita fiscale, contatto principale e configurazione commerciale. Supporta B2B e B2C, clienti italiani ed esteri.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `customer`
--

LOCK TABLES `customer` WRITE;
/*!40000 ALTER TABLE `customer` DISABLE KEYS */;
/*!40000 ALTER TABLE `customer` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `customer_address`
--

DROP TABLE IF EXISTS `customer_address`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `customer_address` (
  `CUSTOMER_ADDRESS_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco dell indirizzo cliente',
  `CUSTOMER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso customer - cliente a cui appartiene questo indirizzo',
  `ADDRESS_TYPE` enum('LEGAL','OPERATIONAL','SHIPPING','BILLING') NOT NULL DEFAULT 'LEGAL' COMMENT 'Tipo indirizzo: LEGAL=sede legale, OPERATIONAL=sede operativa, SHIPPING=consegna merce, BILLING=fatturazione',
  `ADDRESS` varchar(60) NOT NULL COMMENT 'Via e nome della strada',
  `STREET_NUMBER` varchar(8) DEFAULT NULL COMMENT 'Numero civico',
  `POSTAL_CODE` varchar(10) DEFAULT NULL COMMENT 'Codice di avviamento postale - fino a 10 caratteri per formati esteri',
  `FOREIGN_CITY` varchar(60) DEFAULT NULL COMMENT 'Nome della citta per indirizzi esteri non italiani',
  `NATION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso nation - nazione dell indirizzo',
  `MUNICIPALITY_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso municipality - comune italiano, NULL per indirizzi esteri',
  `IS_DEFAULT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e l indirizzo predefinito per il tipo indicato',
  `NOTE` varchar(255) DEFAULT NULL COMMENT 'Note aggiuntive sull indirizzo (es. piano, interno, riferimento consegna)',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`CUSTOMER_ADDRESS_ID`),
  KEY `IDX_CUST_ADDR_CUSTOMER_ID` (`CUSTOMER_ID`),
  KEY `IDX_CUST_ADDR_TYPE` (`ADDRESS_TYPE`),
  KEY `IDX_CUST_ADDR_NATION_ID` (`NATION_ID`),
  KEY `IDX_CUST_ADDR_MUNICIPALITY_ID` (`MUNICIPALITY_ID`),
  KEY `IDX_CUST_ADDR_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_CUST_ADDR_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_CUST_ADDR_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_CUST_ADDR_CUSTOMER_ID` FOREIGN KEY (`CUSTOMER_ID`) REFERENCES `customer` (`CUSTOMER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_CUST_ADDR_MUNICIPALITY_ID` FOREIGN KEY (`MUNICIPALITY_ID`) REFERENCES `municipality` (`MUNICIPALITY_ID`),
  CONSTRAINT `FK_CUST_ADDR_NATION_ID` FOREIGN KEY (`NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_CUST_ADDR_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Indirizzi multipli per cliente - sede legale, operativa, consegna e fatturazione con supporto indirizzi italiani ed esteri';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `customer_address`
--

LOCK TABLES `customer_address` WRITE;
/*!40000 ALTER TABLE `customer_address` DISABLE KEYS */;
/*!40000 ALTER TABLE `customer_address` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `customer_bank`
--

DROP TABLE IF EXISTS `customer_bank`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `customer_bank` (
  `CUSTOMER_BANK_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del conto bancario cliente',
  `CUSTOMER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso customer - cliente a cui appartiene questo conto bancario',
  `BANK_NAME` varchar(100) NOT NULL COMMENT 'Nome o descrizione della banca',
  `BRANCH_NAME` varchar(100) DEFAULT NULL COMMENT 'Nome o descrizione della filiale bancaria',
  `IBAN` varchar(34) NOT NULL COMMENT 'Codice IBAN completo',
  `BIC` varchar(11) DEFAULT NULL COMMENT 'Codice BIC/SWIFT per bonifici internazionali',
  `ABI` char(5) DEFAULT NULL COMMENT 'Codice ABI della banca - 5 cifre',
  `CAB` char(5) DEFAULT NULL COMMENT 'Codice CAB della filiale - 5 cifre',
  `ACCOUNT_NUMBER` char(12) DEFAULT NULL COMMENT 'Numero di conto corrente bancario',
  `IS_PRIMARY` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il conto bancario principale del cliente per addebiti RiBa',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 non piu utilizzato',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`CUSTOMER_BANK_ID`),
  KEY `IDX_CUST_BANK_CUSTOMER_ID` (`CUSTOMER_ID`),
  KEY `IDX_CUST_BANK_IS_PRIMARY` (`IS_PRIMARY`),
  KEY `IDX_CUST_BANK_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_CUST_BANK_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_CUST_BANK_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_CUST_BANK_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_CUST_BANK_CUSTOMER_ID` FOREIGN KEY (`CUSTOMER_ID`) REFERENCES `customer` (`CUSTOMER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_CUST_BANK_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Conti bancari del cliente - supporta piu conti con flag principale per addebito diretto RiBa e pagamenti';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `customer_bank`
--

LOCK TABLES `customer_bank` WRITE;
/*!40000 ALTER TABLE `customer_bank` DISABLE KEYS */;
/*!40000 ALTER TABLE `customer_bank` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `customer_contact`
--

DROP TABLE IF EXISTS `customer_contact`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `customer_contact` (
  `CUSTOMER_CONTACT_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del contatto cliente',
  `CUSTOMER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso customer - cliente a cui appartiene questo contatto',
  `CONTACT_ROLE` enum('PURCHASING','ACCOUNTING','LOGISTICS','GENERAL','MANAGEMENT') NOT NULL DEFAULT 'GENERAL' COMMENT 'Ruolo del contatto: PURCHASING=ufficio acquisti, ACCOUNTING=amministrazione, LOGISTICS=logistica e spedizioni, GENERAL=contatto generico, MANAGEMENT=direzione',
  `FIRST_NAME` varchar(60) DEFAULT NULL COMMENT 'Nome del referente',
  `LAST_NAME` varchar(60) DEFAULT NULL COMMENT 'Cognome del referente',
  `EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email del referente',
  `PHONE` varchar(20) DEFAULT NULL COMMENT 'Numero di telefono fisso del referente',
  `MOBILE` varchar(20) DEFAULT NULL COMMENT 'Numero di cellulare del referente',
  `FAX` varchar(20) DEFAULT NULL COMMENT 'Numero di fax del referente',
  `NOTE` varchar(255) DEFAULT NULL COMMENT 'Note aggiuntive sul contatto (es. orario reperibilita, lingua preferita)',
  `IS_PRIMARY` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il contatto principale per il ruolo indicato',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 non piu referente',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`CUSTOMER_CONTACT_ID`),
  KEY `IDX_CUST_CONTACT_CUSTOMER_ID` (`CUSTOMER_ID`),
  KEY `IDX_CUST_CONTACT_ROLE` (`CONTACT_ROLE`),
  KEY `IDX_CUST_CONTACT_IS_PRIMARY` (`IS_PRIMARY`),
  KEY `IDX_CUST_CONTACT_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_CUST_CONTACT_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_CUST_CONTACT_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_CUST_CONTACT_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_CUST_CONTACT_CUSTOMER_ID` FOREIGN KEY (`CUSTOMER_ID`) REFERENCES `customer` (`CUSTOMER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_CUST_CONTACT_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Contatti aggiuntivi per cliente - referenti con ruolo aziendale per flussi ordini, fatturazione e logistica';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `customer_contact`
--

LOCK TABLES `customer_contact` WRITE;
/*!40000 ALTER TABLE `customer_contact` DISABLE KEYS */;
/*!40000 ALTER TABLE `customer_contact` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `customer_sdi`
--

DROP TABLE IF EXISTS `customer_sdi`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `customer_sdi` (
  `CUSTOMER_SDI_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della configurazione SDI cliente',
  `CUSTOMER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso customer - cliente a cui appartiene questa configurazione SDI',
  `SDI_CODE` varchar(7) DEFAULT NULL COMMENT 'Codice destinatario SDI a 7 caratteri per ricezione fatture elettroniche',
  `PEC` varchar(255) DEFAULT NULL COMMENT 'Indirizzo PEC del cliente - utilizzato come canale alternativo al codice SDI',
  `SDI_FORMAT` enum('FPA12','FPR12') NOT NULL DEFAULT 'FPR12' COMMENT 'Formato XML fattura elettronica: FPA12=Pubblica Amministrazione, FPR12=privati e B2B',
  `DEFAULT_DOCUMENT_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso document_type - tipo documento predefinito per fatture verso questo cliente',
  `DEFAULT_TAX_RATE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate - aliquota IVA predefinita per questo cliente',
  `DEFAULT_EXEMPTION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo E - natura esenzione predefinita per questo cliente',
  `CIG` varchar(15) DEFAULT NULL COMMENT 'Codice Identificativo Gara - obbligatorio per fatture PA con appalti pubblici',
  `CUP` varchar(15) DEFAULT NULL COMMENT 'Codice Unico di Progetto - obbligatorio per fatture PA con progetti pubblici',
  `ORDER_REFERENCE` varchar(20) DEFAULT NULL COMMENT 'Riferimento ordine predefinito da inserire nelle fatture verso questo cliente PA',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`CUSTOMER_SDI_ID`),
  UNIQUE KEY `UQ_CUSTOMER_SDI_CUSTOMER_ID` (`CUSTOMER_ID`),
  KEY `IDX_CUSTOMER_SDI_DOCUMENT_TYPE_ID` (`DEFAULT_DOCUMENT_TYPE_ID`),
  KEY `IDX_CUSTOMER_SDI_TAX_RATE_ID` (`DEFAULT_TAX_RATE_ID`),
  KEY `IDX_CUSTOMER_SDI_EXEMPTION_ID` (`DEFAULT_EXEMPTION_ID`),
  KEY `IDX_CUSTOMER_SDI_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_CUSTOMER_SDI_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_CUSTOMER_SDI_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_CUSTOMER_SDI_CUSTOMER_ID` FOREIGN KEY (`CUSTOMER_ID`) REFERENCES `customer` (`CUSTOMER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_CUSTOMER_SDI_DOCUMENT_TYPE_ID` FOREIGN KEY (`DEFAULT_DOCUMENT_TYPE_ID`) REFERENCES `document_type` (`DOCUMENT_TYPE_ID`),
  CONSTRAINT `FK_CUSTOMER_SDI_EXEMPTION_ID` FOREIGN KEY (`DEFAULT_EXEMPTION_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_CUSTOMER_SDI_TAX_RATE_ID` FOREIGN KEY (`DEFAULT_TAX_RATE_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_CUSTOMER_SDI_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Configurazione SDI e fatturazione elettronica per cliente - codice destinatario, PEC, formato XML e riferimenti PA';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `customer_sdi`
--

LOCK TABLES `customer_sdi` WRITE;
/*!40000 ALTER TABLE `customer_sdi` DISABLE KEYS */;
/*!40000 ALTER TABLE `customer_sdi` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `document_type`
--

DROP TABLE IF EXISTS `document_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `document_type` (
  `DOCUMENT_TYPE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tipo documento',
  `PARENT_DOCUMENT_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso document_type - tipo padre di cui questo e un sottotipo, NULL per tipi di primo livello',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice SDI del tipo documento (es. TD01, TD04, TD24)',
  `DESCRIPTION` varchar(50) NOT NULL COMMENT 'Descrizione del tipo documento',
  `PRINT_DESCRIPTION` varchar(50) DEFAULT NULL COMMENT 'Descrizione da usare esclusivamente nelle stampe',
  `DOC_GROUP` enum('ORDER','DDT','INVOICE','RECEIPT','STORE_AMEND') NOT NULL DEFAULT 'INVOICE' COMMENT 'Gruppo logico: ORDER=preventivi e ordini, DDT=documenti di trasporto, INVOICE=fatture note credito e debito, RECEIPT=ricevute, STORE_AMEND=rettifiche inventariali',
  `SUBTYPE_ORDER` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'Ordine di visualizzazione tra i sottotipi dello stesso padre',
  `IS_CEDENTE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il tipo documento e assegnabile a un cedente',
  `IS_PA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento e indirizzato alla Pubblica Amministrazione',
  `IS_B2B` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento e utilizzato in flussi B2B',
  `IS_BOLLO` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il bollo virtuale si applica a questo tipo documento',
  `IS_BOLLO_NEGATIVE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la riga bollo deve essere inserita con importo negativo',
  `IS_NUMBERED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento richiede numerazione progressiva',
  `IS_STS` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento e utilizzato nel flusso Sistema Tessera Sanitaria',
  `IS_EXPORTABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento puo essere esportato',
  `IS_SDI_SENDABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento puo essere inviato tramite SDI',
  `IS_PROFORMA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento e di tipo proforma',
  `IS_SIMPLIFIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento e una fattura semplificata',
  `IS_WAREHOUSE_FLOW` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il documento genera movimenti di magazzino',
  `FLOW_DIRECTION` tinyint(1) NOT NULL DEFAULT 0 COMMENT 'Direzione del flusso documento: 1=uscita, -1=entrata, 0=neutro',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  PRIMARY KEY (`DOCUMENT_TYPE_ID`),
  UNIQUE KEY `UQ_DOCUMENT_TYPE_CODE` (`CODE`),
  KEY `IDX_DOCUMENT_TYPE_PARENT_ID` (`PARENT_DOCUMENT_TYPE_ID`),
  KEY `IDX_DOCUMENT_TYPE_GROUP` (`DOC_GROUP`),
  KEY `IDX_DOCUMENT_TYPE_IS_ACTIVE` (`IS_ACTIVE`),
  CONSTRAINT `FK_DOCUMENT_TYPE_PARENT_ID` FOREIGN KEY (`PARENT_DOCUMENT_TYPE_ID`) REFERENCES `document_type` (`DOCUMENT_TYPE_ID`) ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica tipi documento - tipi standard SDI con gerarchia padre-figlio (Tipo documento)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `document_type`
--

LOCK TABLES `document_type` WRITE;
/*!40000 ALTER TABLE `document_type` DISABLE KEYS */;
/*!40000 ALTER TABLE `document_type` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `fiscal_regime`
--

DROP TABLE IF EXISTS `fiscal_regime`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `fiscal_regime` (
  `FISCAL_REGIME_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del regime fiscale',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice SDI del regime fiscale (es. RF01, RF19)',
  `DESCRIPTION` varchar(200) NOT NULL COMMENT 'Descrizione completa del regime fiscale',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  PRIMARY KEY (`FISCAL_REGIME_ID`),
  UNIQUE KEY `UQ_FISCAL_REGIME_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tipi di regime fiscale - codici standard SDI (Tipo regime fiscale)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `fiscal_regime`
--

LOCK TABLES `fiscal_regime` WRITE;
/*!40000 ALTER TABLE `fiscal_regime` DISABLE KEYS */;
/*!40000 ALTER TABLE `fiscal_regime` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `invitation`
--

DROP TABLE IF EXISTS `invitation`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `invitation` (
  `INVITATION_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Unique identifier for the invitation record',
  `TOKEN` char(36) NOT NULL COMMENT 'UUID v4 token embedded in the invite link - single use',
  `TENANT_ID` int(10) unsigned NOT NULL COMMENT 'FK to tenant - tenant that owns this invitation',
  `ISSUER_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK to issuer - issuer the invited user will be linked to via user_issuer',
  `EMAIL` varchar(255) DEFAULT NULL COMMENT 'Optional - if set, only this exact email address can consume this invite',
  `USER_TYPE` enum('ADMIN','OPERATOR','DRIVER','CUSTOMER') NOT NULL DEFAULT 'OPERATOR' COMMENT 'Value written to user.USER_TYPE when invite is consumed',
  `ISSUER_ROLE` enum('OWNER','ADMIN','OPERATOR','READONLY') NOT NULL DEFAULT 'OPERATOR' COMMENT 'Value written to user_issuer.ROLE when invite is consumed',
  `STATUS` enum('pending','used','expired','revoked') NOT NULL DEFAULT 'pending' COMMENT 'Current state of the invitation',
  `EXPIRES_AT` datetime NOT NULL COMMENT 'Invite expires 7 days after creation - after this timestamp the token is rejected',
  `USED_AT` datetime DEFAULT NULL COMMENT 'Timestamp when the invite was consumed - null until used',
  `USED_BY` int(10) unsigned DEFAULT NULL COMMENT 'FK to user - the user that registered using this invite',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK to user - the admin who generated this invite',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Record creation timestamp',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Last update timestamp',
  PRIMARY KEY (`INVITATION_ID`),
  UNIQUE KEY `UQ_INVITATION_TOKEN` (`TOKEN`),
  KEY `IDX_INVITATION_TENANT_ID` (`TENANT_ID`),
  KEY `IDX_INVITATION_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_INVITATION_STATUS` (`STATUS`),
  KEY `IDX_INVITATION_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_INVITATION_USED_BY` (`USED_BY`),
  CONSTRAINT `FK_INVITATION_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_INVITATION_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_INVITATION_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`),
  CONSTRAINT `FK_INVITATION_USED_BY` FOREIGN KEY (`USED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Single-use invitation tokens - 7 day expiry - controls tenant onboarding and user access provisioning';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `invitation`
--

LOCK TABLES `invitation` WRITE;
/*!40000 ALTER TABLE `invitation` DISABLE KEYS */;
/*!40000 ALTER TABLE `invitation` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer`
--

DROP TABLE IF EXISTS `issuer`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer` (
  `ISSUER_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del cedente/prestatore',
  `TENANT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso tenant - tenant proprietario del cedente',
  `SUBJECT_TYPE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso subject_type - persona fisica o giuridica',
  `ISSUER_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso issuer_type - tipo soggetto emittente: professionista, CED, studio ecc',
  `BUSINESS_NAME` varchar(80) DEFAULT NULL COMMENT 'Ragione sociale per persone giuridiche',
  `TITLE` varchar(10) DEFAULT NULL COMMENT 'Titolo professionale (es. Dott., Avv.) per persone fisiche',
  `FIRST_NAME` varchar(60) DEFAULT NULL COMMENT 'Nome - utilizzato per persone fisiche',
  `LAST_NAME` varchar(60) DEFAULT NULL COMMENT 'Cognome - utilizzato per persone fisiche',
  `CITIZENSHIP` varchar(60) DEFAULT NULL COMMENT 'Cittadinanza del soggetto per persone fisiche',
  `IDENTIFICATION_NATION_ID` int(10) unsigned NOT NULL COMMENT 'FK verso nation - paese di identificazione fiscale del cedente (identificativo paese SDI)',
  `VAT_NUMBER` varchar(11) DEFAULT NULL COMMENT 'Partita IVA italiana - 11 cifre',
  `TAX_CODE` varchar(16) DEFAULT NULL COMMENT 'Codice fiscale italiano - 16 caratteri',
  `EORI_CODE` varchar(17) DEFAULT NULL COMMENT 'Codice EORI per identificazione doganale',
  `PROFESSIONAL_REGISTER` varchar(60) DEFAULT NULL COMMENT 'Nome dell albo professionale di iscrizione',
  `REGISTER_PROVINCE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso province - provincia dell albo professionale',
  `REGISTER_NUMBER` varchar(60) DEFAULT NULL COMMENT 'Numero di iscrizione all albo professionale',
  `REGISTER_DATE` date DEFAULT NULL COMMENT 'Data di iscrizione all albo professionale',
  `ADDRESS` varchar(60) DEFAULT NULL COMMENT 'Indirizzo della sede legale o operativa',
  `STREET_NUMBER` varchar(8) DEFAULT NULL COMMENT 'Numero civico della sede',
  `FOREIGN_CITY` varchar(60) DEFAULT NULL COMMENT 'Nome della citta per indirizzi esteri non italiani',
  `POSTAL_CODE` char(5) DEFAULT NULL COMMENT 'Codice di avviamento postale (CAP) - 5 cifre',
  `NATION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso nation - nazione della sede legale',
  `MUNICIPALITY_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso municipality - comune italiano della sede legale',
  `PHONE` varchar(12) DEFAULT NULL COMMENT 'Numero di telefono principale',
  `FAX` varchar(12) DEFAULT NULL COMMENT 'Numero di fax',
  `EMAIL` varchar(256) DEFAULT NULL COMMENT 'Indirizzo email principale di contatto',
  `PEC` varchar(256) DEFAULT NULL COMMENT 'Indirizzo PEC del cedente',
  `WEBSITE` varchar(255) DEFAULT NULL COMMENT 'URL del sito web aziendale',
  `DEFAULT_DOCUMENT_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso document_type - tipo documento predefinito per nuovi documenti',
  `FISCAL_REGIME_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso fiscal_regime - regime fiscale attivo del cedente',
  `DEFAULT_TAX_RATE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate - aliquota IVA predefinita da applicare',
  `DEFAULT_TAX_RATE_PREVALENT_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate - aliquota IVA prevalente per scopi statistici',
  `DEFAULT_EXEMPTION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo E - natura esenzione predefinita alternativa all aliquota IVA',
  `DEFAULT_EXEMPTION_PREVALENT_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo E - natura esenzione prevalente',
  `WITHHOLDING_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso withholding_type - tipo ritenuta predefinito',
  `DEFAULT_PAYMENT_REASON_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso payment_reason - causale pagamento predefinita per ritenute',
  `WITHHOLDING_RATE` decimal(5,2) unsigned DEFAULT NULL COMMENT 'Percentuale ritenuta d acconto predefinita',
  `TAXABLE_BASE_PERCENT` decimal(5,2) DEFAULT NULL COMMENT 'Percentuale base imponibile per calcolo ritenuta',
  `PROFESSIONAL_SURCHARGE_PERCENT` decimal(5,2) unsigned DEFAULT NULL COMMENT 'Percentuale di maggiorazione professionale',
  `REA_PROVINCE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso province - ufficio provinciale per iscrizione REA',
  `REA_NUMBER` varchar(20) DEFAULT NULL COMMENT 'Numero REA (Repertorio Economico Amministrativo)',
  `REA_SHARE_CAPITAL` decimal(15,2) unsigned DEFAULT NULL COMMENT 'Capitale sociale per iscrizione REA',
  `REA_SOLE_SHAREHOLDER` enum('SU','SM') DEFAULT NULL COMMENT 'Assetto societario REA: SU=Socio Unico, SM=Soci Multipli',
  `REA_LIQUIDATION_STATUS` enum('LS','LN') DEFAULT NULL COMMENT 'Stato liquidazione REA: LS=In Liquidazione, LN=Non in Liquidazione',
  `LOGO_PATH` varchar(256) DEFAULT NULL COMMENT 'Percorso del file logo del cedente per stampa documenti',
  `DECIMAL_DIGITS_QUANTITY` int(11) NOT NULL DEFAULT 5 COMMENT 'Numero di decimali per i campi quantita nei documenti',
  `IS_SECTION_NUMBERING` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se si utilizza la numerazione per sezionale nei documenti',
  `IS_AUTO_STAMP` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il bollo virtuale viene calcolato automaticamente',
  `IS_ATTACH_PDF_TO_XML` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il PDF deve essere allegato al file XML della fattura elettronica',
  `IS_HIDE_ISSUER_DATA_PRINT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se i dati del cedente devono essere nascosti nella stampa dei documenti',
  `IS_PRINT_DOCUMENT_DATA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se i metadati del documento devono essere stampati nei report',
  `IS_PRINT_TOTALS_LAST_PAGE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se i totali devono essere stampati solo nell ultima pagina',
  `IS_PRINT_CONFORMITY_DESC` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la descrizione copia conforme deve essere stampata',
  `CONFORMITY_DESCRIPTION` varchar(120) NOT NULL DEFAULT 'Copia analogica della fattura elettronica inviata al SDI' COMMENT 'Testo dell etichetta copia conforme stampata sui documenti',
  `IS_PRINT_DISCOUNT_DESC` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la descrizione personalizzata di sconto o abbuono deve essere stampata',
  `DISCOUNT_DESCRIPTION` varchar(120) DEFAULT NULL COMMENT 'Etichetta personalizzata che sostituisce il testo standard di sconto o abbuono in stampa',
  `NOTE_INVOICE` varchar(120) DEFAULT NULL COMMENT 'Nota a pie di pagina stampata sui documenti fattura',
  `NOTE_INVOICE_EN` varchar(120) DEFAULT NULL COMMENT 'Nota a pie di pagina stampata sui documenti fattura in lingua inglese',
  `NOTE_DDT` varchar(120) DEFAULT NULL COMMENT 'Nota a pie di pagina stampata sui documenti DDT',
  `NOTE_PARCELLA` varchar(120) DEFAULT NULL COMMENT 'Nota a pie di pagina stampata sui documenti parcella',
  `NOTE_HEADER_INVOICE` varchar(120) DEFAULT NULL COMMENT 'Nota di intestazione stampata sui documenti fattura',
  `NOTE_HEADER_PARCELLA` varchar(120) DEFAULT NULL COMMENT 'Nota di intestazione stampata sui documenti parcella',
  `IS_ENABLED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il cedente ha firmato il contratto ed e pienamente abilitato',
  `IS_ACCOUNTANT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il profilo del commercialista - prima anagrafica creata per il tenant',
  `IS_ORDER_MEMBER` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il cedente e un commercialista proveniente dall import iniziale dell ordine',
  `IS_MODIFIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se i dati devono essere inviati al gateway per aggiornare i record in SIA',
  `IS_PA_DENIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se l invio alla Pubblica Amministrazione e negato per questo cedente',
  `IS_SETUP_WIZARD_PENDING` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se la procedura guidata di configurazione non e ancora stata completata',
  `IS_STARTUP` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il cedente e configurato come startup',
  `STARTUP_STARTING_DATE` date DEFAULT NULL COMMENT 'Data di avvio del regime startup',
  `IS_NOTIFICATION_ENABLED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se le notifiche email sono abilitate per questo cedente',
  `NOTIFICATION_EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email utilizzato per le notifiche di sistema',
  `IS_CONNECTION_TEST` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la modalita test di connessione e attiva',
  `UI_TYPE` varchar(20) NOT NULL DEFAULT 'NEWUIX' COMMENT 'Versione interfaccia utente utilizzata dal commercialista e dai cedenti secondari',
  `LOGIN_USERNAME` varchar(60) DEFAULT NULL COMMENT 'Username di accesso diretto al sistema se il cedente ha credenziali proprie',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_ID`),
  UNIQUE KEY `UQ_ISSUER_TENANT_VAT` (`TENANT_ID`,`VAT_NUMBER`),
  KEY `IDX_ISSUER_TENANT_ID` (`TENANT_ID`),
  KEY `IDX_ISSUER_SUBJECT_TYPE_ID` (`SUBJECT_TYPE_ID`),
  KEY `IDX_ISSUER_TYPE_ID` (`ISSUER_TYPE_ID`),
  KEY `IDX_ISSUER_IDENTIFICATION_NATION_ID` (`IDENTIFICATION_NATION_ID`),
  KEY `IDX_ISSUER_NATION_ID` (`NATION_ID`),
  KEY `IDX_ISSUER_MUNICIPALITY_ID` (`MUNICIPALITY_ID`),
  KEY `IDX_ISSUER_FISCAL_REGIME_ID` (`FISCAL_REGIME_ID`),
  KEY `IDX_ISSUER_DEFAULT_DOCUMENT_TYPE_ID` (`DEFAULT_DOCUMENT_TYPE_ID`),
  KEY `IDX_ISSUER_DEFAULT_TAX_RATE_ID` (`DEFAULT_TAX_RATE_ID`),
  KEY `IDX_ISSUER_DEFAULT_EXEMPTION_ID` (`DEFAULT_EXEMPTION_ID`),
  KEY `IDX_ISSUER_WITHHOLDING_TYPE_ID` (`WITHHOLDING_TYPE_ID`),
  KEY `IDX_ISSUER_LOGIN_USERNAME` (`LOGIN_USERNAME`),
  KEY `IDX_ISSUER_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_UPDATED_BY` (`UPDATED_BY`),
  KEY `FK_ISSUER_REGISTER_PROVINCE_ID` (`REGISTER_PROVINCE_ID`),
  KEY `FK_ISSUER_REA_PROVINCE_ID` (`REA_PROVINCE_ID`),
  KEY `FK_ISSUER_DEFAULT_TAX_RATE_PREVALENT_ID` (`DEFAULT_TAX_RATE_PREVALENT_ID`),
  KEY `FK_ISSUER_DEFAULT_EXEMPTION_PREVALENT_ID` (`DEFAULT_EXEMPTION_PREVALENT_ID`),
  KEY `FK_ISSUER_DEFAULT_PAYMENT_REASON_ID` (`DEFAULT_PAYMENT_REASON_ID`),
  CONSTRAINT `FK_ISSUER_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_DOCUMENT_TYPE_ID` FOREIGN KEY (`DEFAULT_DOCUMENT_TYPE_ID`) REFERENCES `document_type` (`DOCUMENT_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_EXEMPTION_ID` FOREIGN KEY (`DEFAULT_EXEMPTION_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_EXEMPTION_PREVALENT_ID` FOREIGN KEY (`DEFAULT_EXEMPTION_PREVALENT_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_PAYMENT_REASON_ID` FOREIGN KEY (`DEFAULT_PAYMENT_REASON_ID`) REFERENCES `payment_reason` (`PAYMENT_REASON_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_TAX_RATE_ID` FOREIGN KEY (`DEFAULT_TAX_RATE_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_DEFAULT_TAX_RATE_PREVALENT_ID` FOREIGN KEY (`DEFAULT_TAX_RATE_PREVALENT_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_FISCAL_REGIME_ID` FOREIGN KEY (`FISCAL_REGIME_ID`) REFERENCES `fiscal_regime` (`FISCAL_REGIME_ID`),
  CONSTRAINT `FK_ISSUER_IDENTIFICATION_NATION_ID` FOREIGN KEY (`IDENTIFICATION_NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_ISSUER_ISSUER_TYPE_ID` FOREIGN KEY (`ISSUER_TYPE_ID`) REFERENCES `issuer_type` (`ISSUER_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_MUNICIPALITY_ID` FOREIGN KEY (`MUNICIPALITY_ID`) REFERENCES `municipality` (`MUNICIPALITY_ID`),
  CONSTRAINT `FK_ISSUER_NATION_ID` FOREIGN KEY (`NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_ISSUER_REA_PROVINCE_ID` FOREIGN KEY (`REA_PROVINCE_ID`) REFERENCES `province` (`PROVINCE_ID`),
  CONSTRAINT `FK_ISSUER_REGISTER_PROVINCE_ID` FOREIGN KEY (`REGISTER_PROVINCE_ID`) REFERENCES `province` (`PROVINCE_ID`),
  CONSTRAINT `FK_ISSUER_SUBJECT_TYPE_ID` FOREIGN KEY (`SUBJECT_TYPE_ID`) REFERENCES `subject_type` (`SUBJECT_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`),
  CONSTRAINT `FK_ISSUER_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_WITHHOLDING_TYPE_ID` FOREIGN KEY (`WITHHOLDING_TYPE_ID`) REFERENCES `withholding_type` (`WITHHOLDING_TYPE_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica cedente/prestatore - identita fiscale e anagrafica del soggetto emittente fatture. Collegato al tenant per proprieta e agli utenti tramite user_issuer.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer`
--

LOCK TABLES `issuer` WRITE;
/*!40000 ALTER TABLE `issuer` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_activity`
--

DROP TABLE IF EXISTS `issuer_activity`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_activity` (
  `ISSUER_ACTIVITY_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record attivita cedente',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questa attivita',
  `ATECO_CODE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso ateco_code - codice ATECO assegnato al cedente',
  `IS_PREVALENT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questa e l attivita prevalente in caso di codici ATECO multipli',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_ACTIVITY_ID`),
  UNIQUE KEY `UQ_ISSUER_ACTIVITY_ISSUER_ATECO` (`ISSUER_ID`,`ATECO_CODE_ID`),
  KEY `IDX_ISSUER_ACTIVITY_ATECO_CODE_ID` (`ATECO_CODE_ID`),
  KEY `IDX_ISSUER_ACTIVITY_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_ACTIVITY_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_ACTIVITY_ATECO_CODE_ID` FOREIGN KEY (`ATECO_CODE_ID`) REFERENCES `ateco_code` (`ATECO_CODE_ID`),
  CONSTRAINT `FK_ISSUER_ACTIVITY_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_ACTIVITY_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_ACTIVITY_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Codici attivita ATECO assegnati al cedente - supporta piu codici con flag prevalente';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_activity`
--

LOCK TABLES `issuer_activity` WRITE;
/*!40000 ALTER TABLE `issuer_activity` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_activity` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_b2b`
--

DROP TABLE IF EXISTS `issuer_b2b`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_b2b` (
  `ISSUER_B2B_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della configurazione B2B',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartengono queste credenziali B2B',
  `USERNAME` varchar(80) NOT NULL COMMENT 'Username per accesso al portale B2B dello stato dei documenti',
  `PASSWORD` varchar(255) NOT NULL COMMENT 'Password cifrata per il portale B2B',
  `LDAP_ID` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'ID LDAP del cedente come registrato nel sistema licenze (ID subcliente)',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_B2B_ID`),
  UNIQUE KEY `UQ_ISSUER_B2B_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_B2B_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_B2B_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_B2B_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_B2B_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_B2B_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Credenziali portale B2B per cedente - accesso all area stato documenti B2B';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_b2b`
--

LOCK TABLES `issuer_b2b` WRITE;
/*!40000 ALTER TABLE `issuer_b2b` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_b2b` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_bank`
--

DROP TABLE IF EXISTS `issuer_bank`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_bank` (
  `ISSUER_BANK_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del conto bancario',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questo conto bancario',
  `BANK_NAME` varchar(100) NOT NULL COMMENT 'Nome o descrizione della banca',
  `BRANCH_NAME` varchar(100) NOT NULL COMMENT 'Nome o descrizione della filiale bancaria',
  `IBAN` varchar(34) NOT NULL COMMENT 'Codice IBAN completo',
  `BIC` varchar(11) DEFAULT NULL COMMENT 'Codice BIC/SWIFT per bonifici internazionali',
  `NATION_CODE` char(2) DEFAULT NULL COMMENT 'Prefisso nazione dell IBAN (es. IT, DE)',
  `CHECK_DIGITS` varchar(2) DEFAULT NULL COMMENT 'Cifre di controllo IBAN - 2 caratteri numerici',
  `CIN` char(1) DEFAULT NULL COMMENT 'Carattere di controllo BBAN - lettera maiuscola',
  `ABI` char(5) DEFAULT NULL COMMENT 'Codice ABI della banca - 5 cifre',
  `CAB` char(5) DEFAULT NULL COMMENT 'Codice CAB della filiale - 5 cifre',
  `ACCOUNT_NUMBER` char(12) DEFAULT NULL COMMENT 'Numero di conto corrente bancario',
  `SIA_CODE` varchar(5) DEFAULT NULL COMMENT 'Codice SIA per pagamenti elettronici RiBa',
  `AUTHORIZATION_NUMBER` int(10) DEFAULT NULL COMMENT 'Numero autorizzazione per RiBa',
  `AUTHORIZATION_DATE` date DEFAULT NULL COMMENT 'Data autorizzazione per RiBa',
  `AUTHORIZATION_PROVINCE` varchar(15) DEFAULT NULL COMMENT 'Provincia di autorizzazione per RiBa',
  `RIBA_PRESENTATION_TYPE` enum('AFTER_COLLECTION','GOOD_OUTCOME','DISCOUNT') DEFAULT NULL COMMENT 'Tipo presentazione standard RiBa: AFTER_COLLECTION=dopo incasso, GOOD_OUTCOME=salvo buon fine, DISCOUNT=allo sconto',
  `IS_PRIMARY` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il conto bancario principale del cedente',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 obsoleto non piu utilizzato',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_BANK_ID`),
  KEY `IDX_ISSUER_BANK_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_BANK_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_BANK_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_BANK_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_BANK_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_BANK_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Estremi bancari del cedente - supporta piu conti con flag principale e configurazione RiBa';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_bank`
--

LOCK TABLES `issuer_bank` WRITE;
/*!40000 ALTER TABLE `issuer_bank` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_bank` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_email_config`
--

DROP TABLE IF EXISTS `issuer_email_config`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_email_config` (
  `ISSUER_EMAIL_CONFIG_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della configurazione email',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questa configurazione email',
  `FROM_ADDRESS` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email mittente visualizzato nelle email in uscita',
  `FROM_DESCRIPTION` varchar(250) DEFAULT NULL COMMENT 'Nome mittente visualizzato nelle email in uscita',
  `COMMUNICATIONS_EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email per comunicazioni generali',
  `NOTIFICATION_EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo email per notifiche di sistema',
  `SMTP_USERNAME` varchar(255) DEFAULT NULL COMMENT 'Username per autenticazione SMTP',
  `SMTP_PASSWORD` varchar(45) DEFAULT NULL COMMENT 'Password SMTP cifrata',
  `SMTP_SERVER` varchar(255) DEFAULT NULL COMMENT 'Hostname o IP del server SMTP',
  `SMTP_PORT` int(11) DEFAULT NULL COMMENT 'Porta del server SMTP (es. 587, 465)',
  `IS_SMTP_SSL` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la connessione SMTP utilizza SSL/TLS',
  `IS_SMTP_AUTH` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se il server SMTP richiede autenticazione',
  `IMAP_SERVER` varchar(255) DEFAULT NULL COMMENT 'Hostname o IP del server IMAP per posta in entrata',
  `IMAP_PORT` int(11) DEFAULT NULL COMMENT 'Porta del server IMAP (es. 993)',
  `IS_PERSONAL_ACCOUNT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se si utilizza un account email personale invece della configurazione SMTP',
  `IS_OAUTH2` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se si utilizza autenticazione OAuth2 per l account personale',
  `OAUTH2_PROVIDER` varchar(50) DEFAULT NULL COMMENT 'Nome del provider OAuth2 (es. Google, Microsoft)',
  `OAUTH2_TOKEN_STATUS` varchar(100) DEFAULT NULL COMMENT 'Stato del token OAuth2: acquisito, scaduto ecc',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_EMAIL_CONFIG_ID`),
  UNIQUE KEY `UQ_ISSUER_EMAIL_CONFIG_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_EMAIL_CONFIG_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_EMAIL_CONFIG_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_EMAIL_CONFIG_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_EMAIL_CONFIG_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_EMAIL_CONFIG_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Configurazione server email del cedente - impostazioni SMTP/IMAP e OAuth2 per invio e ricezione documenti';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_email_config`
--

LOCK TABLES `issuer_email_config` WRITE;
/*!40000 ALTER TABLE `issuer_email_config` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_email_config` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_email_template`
--

DROP TABLE IF EXISTS `issuer_email_template`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_email_template` (
  `ISSUER_EMAIL_TEMPLATE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del template email',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questo template',
  `DOCUMENT_TYPE_CODE` varchar(4) NOT NULL COMMENT 'Codice tipo documento a cui si applica il template (es. TD01, BN00=tutti, BN99=estratto conto)',
  `SUBJECT` varchar(255) DEFAULT NULL COMMENT 'Template oggetto dell email',
  `BODY` text DEFAULT NULL COMMENT 'Template corpo dell email in testo semplice o HTML',
  PRIMARY KEY (`ISSUER_EMAIL_TEMPLATE_ID`),
  KEY `IDX_ISSUER_EMAIL_TEMPLATE_ISSUER_ID` (`ISSUER_ID`),
  CONSTRAINT `FK_ISSUER_EMAIL_TEMPLATE_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Template oggetto e corpo email per cedente per tipo documento - per invio automatico documenti ai clienti';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_email_template`
--

LOCK TABLES `issuer_email_template` WRITE;
/*!40000 ALTER TABLE `issuer_email_template` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_email_template` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_file_progressive`
--

DROP TABLE IF EXISTS `issuer_file_progressive`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_file_progressive` (
  `ISSUER_FILE_PROGRESSIVE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del contatore progressivo file',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questo contatore',
  `PROGRESSIVE` varchar(10) NOT NULL COMMENT 'Valore progressivo corrente per la nomenclatura file XML SDI',
  PRIMARY KEY (`ISSUER_FILE_PROGRESSIVE_ID`),
  KEY `IDX_ISSUER_FILE_PROGRESSIVE_ISSUER_ID` (`ISSUER_ID`),
  CONSTRAINT `FK_ISSUER_FILE_PROGRESSIVE_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Contatore progressivo per nomenclatura file per cedente - usato per numerazione progressiva file XML SDI';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_file_progressive`
--

LOCK TABLES `issuer_file_progressive` WRITE;
/*!40000 ALTER TABLE `issuer_file_progressive` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_file_progressive` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_health_card`
--

DROP TABLE IF EXISTS `issuer_health_card`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_health_card` (
  `ISSUER_HEALTH_CARD_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della configurazione tessera sanitaria',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartengono queste credenziali STS',
  `STS_USERNAME` varchar(60) DEFAULT NULL COMMENT 'Username per accesso al portale Sistema Tessera Sanitaria',
  `STS_PASSWORD` varchar(255) DEFAULT NULL COMMENT 'Password cifrata per il portale STS',
  `STS_PIN` varchar(255) DEFAULT NULL COMMENT 'Codice PIN cifrato per il portale STS',
  `TAX_CODE_OVERRIDE` varchar(16) DEFAULT NULL COMMENT 'Codice fiscale alternativo per STS - se valorizzato ha priorita sul codice fiscale del cedente',
  `REGION_CODE` varchar(255) DEFAULT NULL COMMENT 'Codice regione per il sistema STS',
  `ASL_CODE` varchar(255) DEFAULT NULL COMMENT 'Codice ASL (Azienda Sanitaria Locale) per il sistema STS',
  `SSA_CODE` varchar(255) DEFAULT NULL COMMENT 'Codice SSA per il sistema STS',
  `EXPENSE_TYPE` varchar(255) DEFAULT NULL COMMENT 'Tipo spesa predefinito usato nelle comunicazioni STS',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_HEALTH_CARD_ID`),
  UNIQUE KEY `UQ_ISSUER_HEALTH_CARD_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_HEALTH_CARD_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_HEALTH_CARD_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_HEALTH_CARD_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_HEALTH_CARD_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_HEALTH_CARD_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Credenziali e impostazioni Sistema Tessera Sanitaria per cedente - per comunicazione spese mediche';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_health_card`
--

LOCK TABLES `issuer_health_card` WRITE;
/*!40000 ALTER TABLE `issuer_health_card` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_health_card` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_income`
--

DROP TABLE IF EXISTS `issuer_income`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_income` (
  `ISSUER_INCOME_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record reddito',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questo record reddito',
  `FISCAL_YEAR` int(10) unsigned NOT NULL COMMENT 'Anno di esercizio fiscale (es. 2024)',
  `FISCAL_REGIME_ID` int(10) unsigned NOT NULL COMMENT 'FK verso fiscal_regime - regime fiscale attivo durante l anno',
  `INCOME` decimal(15,2) NOT NULL DEFAULT 0.00 COMMENT 'Reddito imponibile totale del cedente nell anno',
  `DEDUCTION` decimal(15,2) NOT NULL DEFAULT 0.00 COMMENT 'Importo deduzione forfettaria',
  `TOTAL_CONTRIBUTIONS_PAID` decimal(15,2) NOT NULL DEFAULT 0.00 COMMENT 'Totale contributi previdenziali versati nell anno',
  `SUBSTITUTIVE_TAX_PERCENT` decimal(15,2) NOT NULL DEFAULT 0.00 COMMENT 'Percentuale imposta sostitutiva applicata per regime forfettario',
  `IS_RECALCULATION_NEEDED` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se i dati reddito devono essere ricalcolati',
  `IS_JOB_PENDING` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il reddito deve essere aggiornato dal job in background appena possibile',
  `LAST_RECALCULATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo ricalcolo reddito completato con successo',
  PRIMARY KEY (`ISSUER_INCOME_ID`),
  UNIQUE KEY `UQ_ISSUER_INCOME_ISSUER_YEAR` (`ISSUER_ID`,`FISCAL_YEAR`),
  KEY `IDX_ISSUER_INCOME_FISCAL_REGIME_ID` (`FISCAL_REGIME_ID`),
  CONSTRAINT `FK_ISSUER_INCOME_FISCAL_REGIME_ID` FOREIGN KEY (`FISCAL_REGIME_ID`) REFERENCES `fiscal_regime` (`FISCAL_REGIME_ID`) ON UPDATE CASCADE,
  CONSTRAINT `FK_ISSUER_INCOME_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Contatori reddito annuali per cedente - per monitoraggio soglie forfettari e calcolo imposte';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_income`
--

LOCK TABLES `issuer_income` WRITE;
/*!40000 ALTER TABLE `issuer_income` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_income` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_preferences`
--

DROP TABLE IF EXISTS `issuer_preferences`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_preferences` (
  `ISSUER_PREFERENCES_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record preferenze',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartengono queste preferenze',
  `DEFAULT_DOCUMENT_TYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso document_type - tipo documento predefinito preferito',
  `DEFAULT_DOCUMENT_SUBTYPE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso document_type - sottotipo XML predefinito preferito',
  `DEFAULT_PAYMENT_MODE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso payment_mode - modalita di pagamento predefinita',
  `DEFERRED_SUBTYPE_CODE` enum('TD24','TD25') NOT NULL DEFAULT 'TD24' COMMENT 'Codice sottotipo XML per fatture differite: TD24 o TD25',
  `STAMP_ARTICLE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso article - articolo usato come riga bollo nei documenti',
  `DEFAULT_PAYMENT_ACCOUNT_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso payment_account - conto di incasso o pagamento predefinito',
  `AUTO_DISCOUNT_THRESHOLD` decimal(15,2) unsigned DEFAULT NULL COMMENT 'Soglia importo per abbuono automatico su pagamento parziale di una scadenza',
  `IS_FORFETTARI_FOOTER_NOTE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la nota legale forfettari deve essere stampata a pie di pagina',
  `IS_FORFETTARI_MODULE_DISABLED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il modulo forfettari e stato volontariamente disattivato dal cedente',
  `IS_XML_NO_QUANTITY_IN_COMMENTS` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se il tag quantita deve essere omesso dalle righe commento nel XML fattura',
  `IS_XML_ACCOUNTING_INFO_IN_ROWS` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se le informazioni sottoconto contabile devono essere incluse nelle righe XML per import in software di contabilita',
  `INVERSION_RECIPIENT_CODE` varchar(7) DEFAULT NULL COMMENT 'Codice destinatario SDI per documenti in inversione contabile o autofatture',
  `IS_NO_PADDING_ROWS` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se le righe vuote di riempimento non devono essere inserite nei report stampati',
  `IS_STAMP_APPLY_RIVALSA` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se l impostazione bollo rivalsa deve essere suggerita automaticamente alla creazione di nuovi clienti',
  `IS_NO_STAMP_ON_DOC_AMENDMENT` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se il bollo non deve essere applicato in fase di variazione di un documento esistente',
  `IS_ART_COUNT_RECONCILIATION` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la ricostruzione delle schede contabili degli articoli e abilitata',
  `PDS_DOCUMENT_IMPORT_DEADLINE` date DEFAULT NULL COMMENT 'Data iniziale di recupero documenti passivi dal Portale dei Servizi',
  `PDS_PAYMENT_ANOMALY_MANAGEMENT` enum('WARNING','CREATE_PAYMENT') DEFAULT NULL COMMENT 'Comportamento in caso di anomalia pagamenti da PdS: WARNING=mostra avviso, CREATE_PAYMENT=crea pagamento automaticamente',
  `PDS_DEFAULT_PAYMENT_MODE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso payment_mode - modalita pagamento predefinita per creazione automatica scadenze da PdS',
  `PDS_IMPORT_EXEMPTION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo E - natura esenzione usata in fase di importazione automatica da PdS',
  `IS_PDS_AUTO_IMPORT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se i documenti passivi dal Portale dei Servizi devono essere importati automaticamente',
  `STATEMENT_EMAIL_SUBJECT` varchar(255) DEFAULT NULL COMMENT 'Template oggetto email per invio estratto conto',
  `STATEMENT_EMAIL_BODY` varchar(255) DEFAULT NULL COMMENT 'Template corpo email per invio estratto conto',
  `REMINDER_EMAIL_SUBJECT` varchar(255) DEFAULT NULL COMMENT 'Template oggetto email per invio sollecito di pagamento',
  `REMINDER_EMAIL_BODY` varchar(255) DEFAULT NULL COMMENT 'Template corpo email per invio sollecito di pagamento',
  `CREATED_BY` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_PREFERENCES_ID`),
  UNIQUE KEY `UQ_ISSUER_PREFERENCES_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_PREFERENCES_DOCUMENT_TYPE_ID` (`DEFAULT_DOCUMENT_TYPE_ID`),
  KEY `IDX_ISSUER_PREFERENCES_PAYMENT_MODE_ID` (`DEFAULT_PAYMENT_MODE_ID`),
  KEY `IDX_ISSUER_PREFERENCES_PAYMENT_ACCOUNT_ID` (`DEFAULT_PAYMENT_ACCOUNT_ID`),
  KEY `IDX_ISSUER_PREFERENCES_PDS_PAYMENT_MODE_ID` (`PDS_DEFAULT_PAYMENT_MODE_ID`),
  KEY `IDX_ISSUER_PREFERENCES_PDS_EXEMPTION_ID` (`PDS_IMPORT_EXEMPTION_ID`),
  KEY `IDX_ISSUER_PREFERENCES_IS_PDS_AUTO_IMPORT` (`IS_PDS_AUTO_IMPORT`),
  KEY `FK_ISSUER_PREFERENCES_DOCUMENT_SUBTYPE_ID` (`DEFAULT_DOCUMENT_SUBTYPE_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_DOCUMENT_SUBTYPE_ID` FOREIGN KEY (`DEFAULT_DOCUMENT_SUBTYPE_ID`) REFERENCES `document_type` (`DOCUMENT_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_DOCUMENT_TYPE_ID` FOREIGN KEY (`DEFAULT_DOCUMENT_TYPE_ID`) REFERENCES `document_type` (`DOCUMENT_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_PREFERENCES_PAYMENT_ACCOUNT_ID` FOREIGN KEY (`DEFAULT_PAYMENT_ACCOUNT_ID`) REFERENCES `payment_account` (`PAYMENT_ACCOUNT_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_PAYMENT_MODE_ID` FOREIGN KEY (`DEFAULT_PAYMENT_MODE_ID`) REFERENCES `payment_mode` (`PAYMENT_MODE_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_PDS_EXEMPTION_ID` FOREIGN KEY (`PDS_IMPORT_EXEMPTION_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_PREFERENCES_PDS_PAYMENT_MODE_ID` FOREIGN KEY (`PDS_DEFAULT_PAYMENT_MODE_ID`) REFERENCES `payment_mode` (`PAYMENT_MODE_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Preferenze operative e comportamentali per cedente - un record per cedente';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_preferences`
--

LOCK TABLES `issuer_preferences` WRITE;
/*!40000 ALTER TABLE `issuer_preferences` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_preferences` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_print_template`
--

DROP TABLE IF EXISTS `issuer_print_template`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_print_template` (
  `ISSUER_PRINT_TEMPLATE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del template di stampa',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui e assegnato questo template',
  `DESCRIPTION` varchar(45) NOT NULL COMMENT 'Etichetta leggibile per questa assegnazione template',
  `TEMPLATE_TYPE` enum('INVOICE','INVOICE_EN','DDT','PARCELLA') NOT NULL COMMENT 'Categoria documento a cui si applica il template: INVOICE=fattura italiana, INVOICE_EN=fattura inglese, DDT=documento di trasporto, PARCELLA=parcella professionale',
  `JRXML_FILE` varchar(150) NOT NULL COMMENT 'Nome del file template JasperReports JRXML',
  `NOTE` varchar(120) DEFAULT NULL COMMENT 'Nota a pie di pagina da stampare sui documenti con questo template',
  `NOTE_HEADER` varchar(120) DEFAULT NULL COMMENT 'Nota di intestazione da stampare sui documenti con questo template',
  `IS_DEFAULT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il template predefinito per il tipo e il cedente',
  `CREATED_BY` int(10) unsigned DEFAULT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned DEFAULT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_PRINT_TEMPLATE_ID`),
  KEY `IDX_ISSUER_PRINT_TEMPLATE_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_PRINT_TEMPLATE_TYPE` (`TEMPLATE_TYPE`),
  KEY `IDX_ISSUER_PRINT_TEMPLATE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_PRINT_TEMPLATE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_PRINT_TEMPLATE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_PRINT_TEMPLATE_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_PRINT_TEMPLATE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Template di stampa per cedente - tabella unificata per tutti i tipi documento: fattura, DDT, parcella, fattura inglese';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_print_template`
--

LOCK TABLES `issuer_print_template` WRITE;
/*!40000 ALTER TABLE `issuer_print_template` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_print_template` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_stable_org`
--

DROP TABLE IF EXISTS `issuer_stable_org`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_stable_org` (
  `ISSUER_STABLE_ORG_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record organizzazione stabile',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questa organizzazione stabile',
  `IDENTIFICATION_NATION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso nation - paese di identificazione fiscale dell organizzazione stabile',
  `VAT_NUMBER` varchar(11) DEFAULT NULL COMMENT 'Partita IVA dell organizzazione stabile',
  `TAX_CODE` varchar(16) DEFAULT NULL COMMENT 'Codice fiscale dell organizzazione stabile',
  `EORI_CODE` varchar(17) DEFAULT NULL COMMENT 'Codice EORI dell organizzazione stabile',
  `BUSINESS_NAME` varchar(80) DEFAULT NULL COMMENT 'Ragione sociale dell organizzazione stabile',
  `FIRST_NAME` varchar(60) DEFAULT NULL COMMENT 'Nome per persone fisiche nell organizzazione stabile',
  `LAST_NAME` varchar(60) DEFAULT NULL COMMENT 'Cognome per persone fisiche nell organizzazione stabile',
  `ADDRESS` varchar(60) DEFAULT NULL COMMENT 'Indirizzo dell organizzazione stabile',
  `STREET_NUMBER` varchar(8) DEFAULT NULL COMMENT 'Numero civico dell organizzazione stabile',
  `POSTAL_CODE` char(5) DEFAULT NULL COMMENT 'CAP dell organizzazione stabile',
  `NATION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso nation - nazione dell organizzazione stabile',
  `MUNICIPALITY_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso municipality - comune italiano dell organizzazione stabile',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_STABLE_ORG_ID`),
  UNIQUE KEY `UQ_ISSUER_STABLE_ORG_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_STABLE_ORG_NATION_ID` (`NATION_ID`),
  KEY `IDX_ISSUER_STABLE_ORG_MUNICIPALITY_ID` (`MUNICIPALITY_ID`),
  KEY `IDX_ISSUER_STABLE_ORG_IDENTIFICATION_NATION_ID` (`IDENTIFICATION_NATION_ID`),
  KEY `FK_ISSUER_STABLE_ORG_CREATED_BY` (`CREATED_BY`),
  KEY `FK_ISSUER_STABLE_ORG_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_STABLE_ORG_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_STABLE_ORG_IDENTIFICATION_NATION_ID` FOREIGN KEY (`IDENTIFICATION_NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_ISSUER_STABLE_ORG_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_STABLE_ORG_MUNICIPALITY_ID` FOREIGN KEY (`MUNICIPALITY_ID`) REFERENCES `municipality` (`MUNICIPALITY_ID`),
  CONSTRAINT `FK_ISSUER_STABLE_ORG_NATION_ID` FOREIGN KEY (`NATION_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_ISSUER_STABLE_ORG_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dati organizzazione stabile del cedente - identita legale e fiscale quando diversa dalla sede operativa';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_stable_org`
--

LOCK TABLES `issuer_stable_org` WRITE;
/*!40000 ALTER TABLE `issuer_stable_org` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_stable_org` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_type`
--

DROP TABLE IF EXISTS `issuer_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_type` (
  `ISSUER_TYPE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tipo soggetto emittente',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice breve (es. CED=Cedente, PRO=Professionista, STU=Studio)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione del tipo soggetto emittente',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  PRIMARY KEY (`ISSUER_TYPE_ID`),
  UNIQUE KEY `UQ_ISSUER_TYPE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tipi soggetto emittente documenti - professionista, CED, studio ecc. (Tipo soggetto emittente)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_type`
--

LOCK TABLES `issuer_type` WRITE;
/*!40000 ALTER TABLE `issuer_type` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_type` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_welfare_fund`
--

DROP TABLE IF EXISTS `issuer_welfare_fund`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_welfare_fund` (
  `ISSUER_WELFARE_FUND_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della configurazione cassa previdenziale',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questa configurazione cassa',
  `WELFARE_FUND_TYPE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso welfare_fund_type - tipo di cassa previdenziale o assistenziale',
  `FUND_RATE` decimal(5,3) unsigned NOT NULL COMMENT 'Aliquota percentuale del contributo alla cassa previdenziale',
  `TAX_RATE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo T - aliquota IVA applicata a questa cassa',
  `EXEMPTION_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate tipo E - natura esenzione applicata a questa cassa in alternativa all aliquota IVA',
  `IS_WITHHOLDING` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questa cassa e soggetta a ritenuta d acconto',
  `IS_EXCLUDED_FROM_NET` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questa cassa e esclusa dal calcolo del netto a pagare',
  `ADMIN_REFERENCE` varchar(20) DEFAULT NULL COMMENT 'Riferimento amministrativo per questa configurazione cassa',
  `NORMATIVE_REFERENCE` varchar(100) DEFAULT NULL COMMENT 'Riferimento normativo o di legge per questa configurazione cassa',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva selezionabile nel dettaglio rigo documento, 0 non piu selezionabile',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_WELFARE_FUND_ID`),
  KEY `IDX_ISSUER_WELFARE_FUND_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_WELFARE_FUND_TYPE_ID` (`WELFARE_FUND_TYPE_ID`),
  KEY `IDX_ISSUER_WELFARE_FUND_TAX_RATE_ID` (`TAX_RATE_ID`),
  KEY `IDX_ISSUER_WELFARE_FUND_EXEMPTION_ID` (`EXEMPTION_ID`),
  KEY `IDX_ISSUER_WELFARE_FUND_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_WELFARE_FUND_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_EXEMPTION_ID` FOREIGN KEY (`EXEMPTION_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_TAX_RATE_ID` FOREIGN KEY (`TAX_RATE_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_TYPE_ID` FOREIGN KEY (`WELFARE_FUND_TYPE_ID`) REFERENCES `welfare_fund_type` (`WELFARE_FUND_TYPE_ID`),
  CONSTRAINT `FK_ISSUER_WELFARE_FUND_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Configurazioni casse previdenziali per cedente - ogni cedente puo avere piu configurazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_welfare_fund`
--

LOCK TABLES `issuer_welfare_fund` WRITE;
/*!40000 ALTER TABLE `issuer_welfare_fund` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_welfare_fund` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `issuer_wizard`
--

DROP TABLE IF EXISTS `issuer_wizard`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `issuer_wizard` (
  `ISSUER_WIZARD_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record wizard',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui appartiene questo stato wizard',
  `SIGNATURE_TYPE` enum('DIGITAL','ANALOG') DEFAULT NULL COMMENT 'Tipo firma scelto durante il wizard: DIGITAL=firma digitale, ANALOG=firma analogica',
  `IS_TEST_PASSED` tinyint(1) unsigned DEFAULT NULL COMMENT '1 se il test di connessione durante il wizard si e completato con successo',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`ISSUER_WIZARD_ID`),
  KEY `IDX_ISSUER_WIZARD_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_ISSUER_WIZARD_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_ISSUER_WIZARD_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_ISSUER_WIZARD_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_ISSUER_WIZARD_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_ISSUER_WIZARD_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Stato procedura guidata di configurazione per cedente - memorizza le scelte effettuate durante il wizard di onboarding';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `issuer_wizard`
--

LOCK TABLES `issuer_wizard` WRITE;
/*!40000 ALTER TABLE `issuer_wizard` DISABLE KEYS */;
/*!40000 ALTER TABLE `issuer_wizard` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `municipality`
--

DROP TABLE IF EXISTS `municipality`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `municipality` (
  `MUNICIPALITY_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del comune',
  `PROVINCE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso province - provincia di appartenenza del comune',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome del comune (es. Milano, Napoli)',
  `ISTAT_CODE` varchar(10) NOT NULL COMMENT 'Codice ISTAT numerico del comune',
  `CADASTRAL_CODE` varchar(5) DEFAULT NULL COMMENT 'Codice catastale del comune (es. F205 per Milano)',
  `CAP` varchar(5) DEFAULT NULL COMMENT 'Codice di avviamento postale principale (CAP)',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 soppresso o accorpato',
  PRIMARY KEY (`MUNICIPALITY_ID`),
  UNIQUE KEY `UQ_MUNICIPALITY_ISTAT_CODE` (`ISTAT_CODE`),
  KEY `IDX_MUNICIPALITY_PROVINCE_ID` (`PROVINCE_ID`),
  KEY `IDX_MUNICIPALITY_CADASTRAL_CODE` (`CADASTRAL_CODE`),
  CONSTRAINT `FK_MUNICIPALITY_PROVINCE_ID` FOREIGN KEY (`PROVINCE_ID`) REFERENCES `province` (`PROVINCE_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica comuni italiani ed equivalenti per altre nazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `municipality`
--

LOCK TABLES `municipality` WRITE;
/*!40000 ALTER TABLE `municipality` DISABLE KEYS */;
/*!40000 ALTER TABLE `municipality` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `nation`
--

DROP TABLE IF EXISTS `nation`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `nation` (
  `NATION_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della nazione',
  `CODE` char(2) NOT NULL COMMENT 'Codice ISO 3166-1 alpha-2 (es. IT, DE, FR)',
  `CODE_3` char(3) DEFAULT NULL COMMENT 'Codice ISO 3166-1 alpha-3 (es. ITA, DEU, FRA)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome completo della nazione',
  `PHONE_PREFIX` varchar(5) DEFAULT NULL COMMENT 'Prefisso telefonico internazionale (es. +39, +1)',
  `FLAG_EMOJI` varchar(10) DEFAULT NULL COMMENT 'Emoji della bandiera nazionale',
  `IS_EU` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se la nazione appartiene all Unione Europea',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`NATION_ID`),
  UNIQUE KEY `UQ_NATION_CODE` (`CODE`),
  UNIQUE KEY `UQ_NATION_CODE_3` (`CODE_3`),
  KEY `IDX_NATION_IS_ACTIVE` (`IS_ACTIVE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica nazioni - basata su standard ISO 3166. Unifica country e fat_nazione.';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `nation`
--

LOCK TABLES `nation` WRITE;
/*!40000 ALTER TABLE `nation` DISABLE KEYS */;
/*!40000 ALTER TABLE `nation` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `otp`
--

DROP TABLE IF EXISTS `otp`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `otp` (
  `OTP_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del codice OTP',
  `USER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente a cui appartiene il codice OTP',
  `CODE` varchar(6) NOT NULL COMMENT 'Codice OTP a 6 cifre',
  `PURPOSE` enum('REGISTER','LOGIN','RESET_PASSWORD','VERIFY_PHONE','VERIFY_EMAIL') NOT NULL COMMENT 'Scopo del codice OTP: REGISTER=registrazione, LOGIN=accesso, RESET_PASSWORD=recupero password, VERIFY_PHONE=verifica telefono, VERIFY_EMAIL=verifica email',
  `ATTEMPTS` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'Numero di tentativi di verifica effettuati',
  `IS_USED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '0=non ancora utilizzato, 1=gia utilizzato',
  `USED_AT` datetime DEFAULT NULL COMMENT 'Data e ora in cui il codice OTP e stato utilizzato',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di generazione del codice OTP',
  `EXPIRES_AT` datetime NOT NULL COMMENT 'Data e ora di scadenza del codice OTP',
  PRIMARY KEY (`OTP_ID`),
  KEY `IDX_OTP_USER_ID` (`USER_ID`),
  KEY `IDX_OTP_CODE` (`CODE`),
  KEY `IDX_OTP_EXPIRES` (`EXPIRES_AT`),
  KEY `IDX_OTP_IS_USED` (`IS_USED`),
  CONSTRAINT `FK_OTP_USER_ID` FOREIGN KEY (`USER_ID`) REFERENCES `user` (`USER_ID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Codici OTP per flussi di verifica - registrazione, login, recupero password, verifica contatti';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `otp`
--

LOCK TABLES `otp` WRITE;
/*!40000 ALTER TABLE `otp` DISABLE KEYS */;
INSERT INTO `otp` VALUES (3,5,'310204','REGISTER',0,1,'2026-03-13 22:16:24','2026-03-13 22:16:00','2026-03-13 22:26:00'),(4,6,'644974','REGISTER',0,0,NULL,'2026-03-17 16:31:49','2026-03-17 16:41:49'),(5,7,'881841','REGISTER',0,0,NULL,'2026-03-17 16:54:57','2026-03-17 17:04:57'),(6,8,'747927','REGISTER',0,0,NULL,'2026-03-17 17:09:04','2026-03-17 17:19:04'),(7,9,'321792','REGISTER',0,1,NULL,'2026-03-17 17:22:25','2026-03-17 17:32:25'),(8,9,'942746','REGISTER',0,0,NULL,'2026-03-17 17:28:28','2026-03-17 17:38:28'),(9,10,'224142','REGISTER',0,1,'2026-03-19 09:43:28','2026-03-19 09:42:40','2026-03-19 09:52:40'),(10,12,'923117','REGISTER',0,1,NULL,'2026-03-19 09:44:45','2026-03-19 09:54:45'),(11,12,'815966','REGISTER',0,0,NULL,'2026-03-19 16:13:31','2026-03-19 16:23:31'),(12,13,'408778','REGISTER',0,1,NULL,'2026-03-19 16:25:40','2026-03-19 16:35:40'),(13,13,'467426','REGISTER',0,0,NULL,'2026-03-19 16:41:09','2026-03-19 16:51:09'),(14,14,'815134','REGISTER',0,1,'2026-03-26 16:34:48','2026-03-26 16:34:00','2026-03-26 16:44:00'),(15,15,'262765','REGISTER',0,1,'2026-03-30 15:59:42','2026-03-30 15:58:58','2026-03-30 16:08:58');
/*!40000 ALTER TABLE `otp` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `payment_account`
--

DROP TABLE IF EXISTS `payment_account`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `payment_account` (
  `PAYMENT_ACCOUNT_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del conto di pagamento',
  `ISSUER_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso issuer - NULL indica conto condiviso di sistema, valorizzato indica conto specifico del cedente',
  `CODE` varchar(50) NOT NULL COMMENT 'Codice del conto di pagamento o incasso',
  `DESCRIPTION` varchar(50) NOT NULL COMMENT 'Descrizione del conto di pagamento o incasso',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PAYMENT_ACCOUNT_ID`),
  UNIQUE KEY `UQ_PAYMENT_ACCOUNT_CODE_ISSUER` (`CODE`,`ISSUER_ID`),
  KEY `IDX_PAYMENT_ACCOUNT_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_PAYMENT_ACCOUNT_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PAYMENT_ACCOUNT_UPDATED_BY` (`UPDATED_BY`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Conti di incasso e pagamento - di sistema o specifici per cedente (Conti di incasso e pagamento)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `payment_account`
--

LOCK TABLES `payment_account` WRITE;
/*!40000 ALTER TABLE `payment_account` DISABLE KEYS */;
/*!40000 ALTER TABLE `payment_account` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `payment_mode`
--

DROP TABLE IF EXISTS `payment_mode`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `payment_mode` (
  `PAYMENT_MODE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della modalita di pagamento',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice SDI modalita pagamento (es. MP01=contanti, MP05=bonifico bancario)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione della modalita di pagamento',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`PAYMENT_MODE_ID`),
  UNIQUE KEY `UQ_PAYMENT_MODE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Modalita di pagamento per scadenze fattura - codici standard SDI (Modalita di pagamento)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `payment_mode`
--

LOCK TABLES `payment_mode` WRITE;
/*!40000 ALTER TABLE `payment_mode` DISABLE KEYS */;
/*!40000 ALTER TABLE `payment_mode` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `payment_reason`
--

DROP TABLE IF EXISTS `payment_reason`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `payment_reason` (
  `PAYMENT_REASON_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della causale pagamento',
  `CODE` varchar(2) NOT NULL COMMENT 'Codice breve (es. A, B, V) - causale IRPEF per ritenute',
  `DESCRIPTION` varchar(500) NOT NULL COMMENT 'Descrizione completa della causale pagamento',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`PAYMENT_REASON_ID`),
  UNIQUE KEY `UQ_PAYMENT_REASON_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Causali pagamento per ritenute d acconto (Causale pagamento ritenuta)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `payment_reason`
--

LOCK TABLES `payment_reason` WRITE;
/*!40000 ALTER TABLE `payment_reason` DISABLE KEYS */;
/*!40000 ALTER TABLE `payment_reason` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `price_list`
--

DROP TABLE IF EXISTS `price_list`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `price_list` (
  `PRICE_LIST_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del listino prezzi',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente proprietario del listino',
  `CODE` varchar(20) NOT NULL COMMENT 'Codice breve identificativo del listino (es. DEFAULT, GROSSISTI, VIP)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome descrittivo del listino prezzi',
  `CURRENCY` char(3) NOT NULL DEFAULT 'EUR' COMMENT 'Codice valuta ISO 4217 del listino (es. EUR, USD, GBP)',
  `DISCOUNT_PERCENT` decimal(5,2) NOT NULL DEFAULT 0.00 COMMENT 'Sconto percentuale generale applicato a tutti i prezzi del listino',
  `VALID_FROM` date DEFAULT NULL COMMENT 'Data di inizio validita del listino - NULL indica validita immediata',
  `VALID_TO` date DEFAULT NULL COMMENT 'Data di fine validita del listino - NULL indica validita illimitata',
  `IS_DEFAULT` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questo e il listino predefinito del cedente applicato ai clienti senza listino specifico',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRICE_LIST_ID`),
  UNIQUE KEY `UQ_PRICE_LIST_CODE_ISSUER` (`CODE`,`ISSUER_ID`),
  KEY `IDX_PRICE_LIST_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_PRICE_LIST_IS_DEFAULT` (`IS_DEFAULT`),
  KEY `IDX_PRICE_LIST_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_PRICE_LIST_VALID_FROM` (`VALID_FROM`),
  KEY `IDX_PRICE_LIST_VALID_TO` (`VALID_TO`),
  KEY `IDX_PRICE_LIST_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PRICE_LIST_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PRICE_LIST_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PRICE_LIST_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`),
  CONSTRAINT `FK_PRICE_LIST_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Listini prezzi nominati per cedente - supporta piu listini con validita temporale e sconto generale';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `price_list`
--

LOCK TABLES `price_list` WRITE;
/*!40000 ALTER TABLE `price_list` DISABLE KEYS */;
/*!40000 ALTER TABLE `price_list` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product`
--

DROP TABLE IF EXISTS `product`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product` (
  `PRODUCT_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del prodotto',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente proprietario del prodotto',
  `PRODUCT_CATEGORY_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso product_category - categoria di appartenenza del prodotto',
  `TAX_RATE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate - aliquota IVA applicata al prodotto',
  `BASE_UNIT_OF_MEASURE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso unit_of_measure - unita di misura base per gestione interna e magazzino',
  `SALE_UNIT_OF_MEASURE_ID` int(10) unsigned NOT NULL COMMENT 'FK verso unit_of_measure - unita di misura utilizzata nei documenti di vendita',
  `SALE_UNIT_CONVERSION_FACTOR` decimal(10,5) NOT NULL DEFAULT 1.00000 COMMENT 'Fattore di conversione tra unita di vendita e unita base (es. 6.000 se una confezione contiene 6 pezzi)',
  `CODE` varchar(50) DEFAULT NULL COMMENT 'Codice interno del prodotto assegnato dal cedente',
  `NAME` varchar(150) NOT NULL COMMENT 'Nome commerciale del prodotto',
  `DESCRIPTION` text DEFAULT NULL COMMENT 'Descrizione estesa del prodotto per documenti e catalogo',
  `BARCODE_EAN13` varchar(13) DEFAULT NULL COMMENT 'Codice a barre EAN-13 del prodotto',
  `BARCODE_QR` varchar(255) DEFAULT NULL COMMENT 'Contenuto del codice QR del prodotto',
  `BARCODE_INTERNAL` varchar(50) DEFAULT NULL COMMENT 'Codice a barre interno personalizzato del cedente',
  `PURCHASE_PRICE` decimal(15,5) DEFAULT NULL COMMENT 'Prezzo di acquisto o costo unitario del prodotto',
  `SALE_PRICE` decimal(15,5) DEFAULT NULL COMMENT 'Prezzo di vendita base del prodotto prima di sconti o listini',
  `MIN_STOCK_LEVEL` decimal(15,5) NOT NULL DEFAULT 0.00000 COMMENT 'Soglia minima di giacenza per avviso scorta minima',
  `MAX_STOCK_LEVEL` decimal(15,5) DEFAULT NULL COMMENT 'Soglia massima di giacenza per avviso sovrascorta',
  `STATUS` enum('DRAFT','PUBLISHED','DISCONTINUED') NOT NULL DEFAULT 'DRAFT' COMMENT 'Stato del ciclo di vita: DRAFT=in elaborazione, PUBLISHED=pubblicato e ordinabile, DISCONTINUED=fuori produzione ma vendibile fino ad esaurimento scorte',
  `IS_COMPOSITE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e composto da altri articoli - riservato per futuro modulo distinta base',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 archiviato o obsoleto',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_ID`),
  UNIQUE KEY `UQ_PRODUCT_CODE_ISSUER` (`CODE`,`ISSUER_ID`),
  UNIQUE KEY `UQ_PRODUCT_BARCODE_EAN13_ISSUER` (`BARCODE_EAN13`,`ISSUER_ID`),
  KEY `IDX_PRODUCT_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_PRODUCT_CATEGORY_ID` (`PRODUCT_CATEGORY_ID`),
  KEY `IDX_PRODUCT_TAX_RATE_ID` (`TAX_RATE_ID`),
  KEY `IDX_PRODUCT_BASE_UOM_ID` (`BASE_UNIT_OF_MEASURE_ID`),
  KEY `IDX_PRODUCT_SALE_UOM_ID` (`SALE_UNIT_OF_MEASURE_ID`),
  KEY `IDX_PRODUCT_STATUS` (`STATUS`),
  KEY `IDX_PRODUCT_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_PRODUCT_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PRODUCT_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PRODUCT_BASE_UOM_ID` FOREIGN KEY (`BASE_UNIT_OF_MEASURE_ID`) REFERENCES `unit_of_measure` (`UNIT_OF_MEASURE_ID`),
  CONSTRAINT `FK_PRODUCT_CATEGORY_ID` FOREIGN KEY (`PRODUCT_CATEGORY_ID`) REFERENCES `product_category` (`PRODUCT_CATEGORY_ID`) ON UPDATE CASCADE,
  CONSTRAINT `FK_PRODUCT_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PRODUCT_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`),
  CONSTRAINT `FK_PRODUCT_SALE_UOM_ID` FOREIGN KEY (`SALE_UNIT_OF_MEASURE_ID`) REFERENCES `unit_of_measure` (`UNIT_OF_MEASURE_ID`),
  CONSTRAINT `FK_PRODUCT_TAX_RATE_ID` FOREIGN KEY (`TAX_RATE_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`),
  CONSTRAINT `FK_PRODUCT_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica prodotti per cedente - unita vendibile con prezzi, codici a barre e unita di misura';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product`
--

LOCK TABLES `product` WRITE;
/*!40000 ALTER TABLE `product` DISABLE KEYS */;
/*!40000 ALTER TABLE `product` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_category`
--

DROP TABLE IF EXISTS `product_category`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_category` (
  `PRODUCT_CATEGORY_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della categoria prodotto',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente proprietario della categoria',
  `PARENT_PRODUCT_CATEGORY_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso product_category - categoria padre per struttura gerarchica, NULL per categorie di primo livello',
  `CATEGORY_TYPE` enum('FOOD','JEWELRY','CLOTHING','BUILDING','PHARMA','ELECTRONICS','AUTOMOTIVE','FURNITURE','AGRICULTURE','PRINTING','GENERIC') NOT NULL DEFAULT 'GENERIC' COMMENT 'Verticale di business: FOOD=alimentari, JEWELRY=orafo, CLOTHING=abbigliamento, BUILDING=edilizia, PHARMA=farmacia, ELECTRONICS=elettronica, AUTOMOTIVE=ricambi auto, FURNITURE=arredamento, AGRICULTURE=agricoltura, PRINTING=tipografia, GENERIC=generico',
  `CODE` varchar(20) DEFAULT NULL COMMENT 'Codice breve identificativo della categoria per uso interno',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome descrittivo della categoria prodotto',
  `SORT_ORDER` int(10) unsigned NOT NULL DEFAULT 0 COMMENT 'Ordine di visualizzazione tra categorie dello stesso livello',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_CATEGORY_ID`),
  KEY `IDX_PROD_CAT_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_PROD_CAT_PARENT_ID` (`PARENT_PRODUCT_CATEGORY_ID`),
  KEY `IDX_PROD_CAT_TYPE` (`CATEGORY_TYPE`),
  KEY `IDX_PROD_CAT_IS_ACTIVE` (`IS_ACTIVE`),
  KEY `IDX_PROD_CAT_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_CAT_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_CAT_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_CAT_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`),
  CONSTRAINT `FK_PROD_CAT_PARENT_ID` FOREIGN KEY (`PARENT_PRODUCT_CATEGORY_ID`) REFERENCES `product_category` (`PRODUCT_CATEGORY_ID`) ON UPDATE CASCADE,
  CONSTRAINT `FK_PROD_CAT_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Categorie prodotti per cedente - struttura gerarchica con verticale di business';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_category`
--

LOCK TABLES `product_category` WRITE;
/*!40000 ALTER TABLE `product_category` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_category` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail`
--

DROP TABLE IF EXISTS `product_detail`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail` (
  `PRODUCT_DETAIL_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record dettaglio prodotto',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto a cui appartiene questo dettaglio',
  `COUNTRY_OF_ORIGIN_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso nation - paese di origine o produzione del prodotto',
  `WEIGHT_UOM_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso unit_of_measure - unita di misura del peso (es. KG, GR)',
  `DIMENSION_UOM_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso unit_of_measure - unita di misura delle dimensioni (es. CM, MM, MT)',
  `VOLUME_UOM_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso unit_of_measure - unita di misura del volume (es. LT, ML, CL)',
  `WEIGHT` decimal(10,4) DEFAULT NULL COMMENT 'Peso del prodotto nell unita di misura indicata in WEIGHT_UOM_ID',
  `WIDTH` decimal(10,4) DEFAULT NULL COMMENT 'Larghezza del prodotto nell unita di misura indicata in DIMENSION_UOM_ID',
  `HEIGHT` decimal(10,4) DEFAULT NULL COMMENT 'Altezza del prodotto nell unita di misura indicata in DIMENSION_UOM_ID',
  `DEPTH` decimal(10,4) DEFAULT NULL COMMENT 'Profondita o spessore del prodotto nell unita di misura indicata in DIMENSION_UOM_ID',
  `VOLUME` decimal(10,4) DEFAULT NULL COMMENT 'Volume del prodotto nell unita di misura indicata in VOLUME_UOM_ID',
  `IS_HAZARDOUS` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e classificato come pericoloso o soggetto a normative ADR',
  `IS_PERISHABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e deperibile e soggetto a data di scadenza',
  `IS_FRAGILE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto richiede manipolazione fragile durante trasporto e stoccaggio',
  `NOTES` text DEFAULT NULL COMMENT 'Note tecniche o logistiche aggiuntive sul prodotto',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_ID`),
  UNIQUE KEY `UQ_PRODUCT_DETAIL_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_COUNTRY_ID` (`COUNTRY_OF_ORIGIN_ID`),
  KEY `IDX_PROD_DETAIL_WEIGHT_UOM_ID` (`WEIGHT_UOM_ID`),
  KEY `IDX_PROD_DETAIL_DIMENSION_UOM_ID` (`DIMENSION_UOM_ID`),
  KEY `IDX_PROD_DETAIL_VOLUME_UOM_ID` (`VOLUME_UOM_ID`),
  KEY `IDX_PROD_DETAIL_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_COUNTRY_ID` FOREIGN KEY (`COUNTRY_OF_ORIGIN_ID`) REFERENCES `nation` (`NATION_ID`),
  CONSTRAINT `FK_PROD_DETAIL_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_DIMENSION_UOM_ID` FOREIGN KEY (`DIMENSION_UOM_ID`) REFERENCES `unit_of_measure` (`UNIT_OF_MEASURE_ID`),
  CONSTRAINT `FK_PROD_DETAIL_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_VOLUME_UOM_ID` FOREIGN KEY (`VOLUME_UOM_ID`) REFERENCES `unit_of_measure` (`UNIT_OF_MEASURE_ID`),
  CONSTRAINT `FK_PROD_DETAIL_WEIGHT_UOM_ID` FOREIGN KEY (`WEIGHT_UOM_ID`) REFERENCES `unit_of_measure` (`UNIT_OF_MEASURE_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio esteso comune del prodotto - dimensioni, peso, volume e attributi logistici validi per tutti i verticali';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail`
--

LOCK TABLES `product_detail` WRITE;
/*!40000 ALTER TABLE `product_detail` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_agriculture`
--

DROP TABLE IF EXISTS `product_detail_agriculture`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_agriculture` (
  `PRODUCT_DETAIL_AGRICULTURE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio prodotto agricolo',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto agricolo a cui appartiene questo dettaglio',
  `VARIETY` varchar(100) DEFAULT NULL COMMENT 'Varieta o cultivar del prodotto agricolo (es. Gala per mele, Arborio per riso)',
  `HARVEST_SEASON` varchar(50) DEFAULT NULL COMMENT 'Stagione o periodo di raccolta (es. Settembre-Ottobre)',
  `PRODUCTION_METHOD` enum('CONVENTIONAL','ORGANIC','BIODYNAMIC','INTEGRATED') DEFAULT NULL COMMENT 'Metodo di produzione: CONVENTIONAL=convenzionale, ORGANIC=biologico, BIODYNAMIC=biodinamico, INTEGRATED=integrato',
  `CERTIFICATION_CODE` varchar(100) DEFAULT NULL COMMENT 'Codice o numero certificazione biologica o DOP/IGP/STG',
  `GEOGRAPHIC_INDICATION` enum('DOP','IGP','STG','DOC','DOCG','IGT','NONE') NOT NULL DEFAULT 'NONE' COMMENT 'Indicazione geografica: DOP, IGP, STG, DOC, DOCG, IGT o NONE',
  `IS_BIO` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato biologico',
  `IS_GMO_FREE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato privo di OGM',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_AGRICULTURE_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_AGRICULTURE_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_AGRICULTURE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_AGRICULTURE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_AGRICULTURE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_AGRICULTURE_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_AGRICULTURE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti agricoli - varieta, metodo di produzione e indicazioni geografiche';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_agriculture`
--

LOCK TABLES `product_detail_agriculture` WRITE;
/*!40000 ALTER TABLE `product_detail_agriculture` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_agriculture` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_automotive`
--

DROP TABLE IF EXISTS `product_detail_automotive`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_automotive` (
  `PRODUCT_DETAIL_AUTOMOTIVE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio ricambio auto',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - ricambio auto a cui appartiene questo dettaglio',
  `OEM_CODE` varchar(100) DEFAULT NULL COMMENT 'Codice OEM originale del produttore del veicolo',
  `AFTERMARKET_CODE` varchar(100) DEFAULT NULL COMMENT 'Codice aftermarket del produttore del ricambio',
  `COMPATIBLE_MAKES` varchar(500) DEFAULT NULL COMMENT 'Marche di veicoli compatibili (es. Fiat, Ford, Volkswagen)',
  `COMPATIBLE_MODELS` varchar(500) DEFAULT NULL COMMENT 'Modelli di veicoli compatibili (es. Panda, Punto, Golf)',
  `COMPATIBLE_YEARS` varchar(50) DEFAULT NULL COMMENT 'Anno o range di anni di produzione compatibili (es. 2010-2018)',
  `PART_CATEGORY` varchar(100) DEFAULT NULL COMMENT 'Categoria del ricambio (es. Motore, Freni, Sospensioni, Carrozzeria)',
  `IS_OEM` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il ricambio e originale OEM, 0 se aftermarket o compatibile',
  `IS_REMANUFACTURED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il ricambio e rigenerato o ricondizionato',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_AUTOMOTIVE_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_AUTOMOTIVE_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_AUTOMOTIVE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_AUTOMOTIVE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_AUTOMOTIVE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_AUTOMOTIVE_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_AUTOMOTIVE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio ricambi e accessori auto - codici OEM, compatibilita veicoli e categoria ricambio';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_automotive`
--

LOCK TABLES `product_detail_automotive` WRITE;
/*!40000 ALTER TABLE `product_detail_automotive` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_automotive` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_building`
--

DROP TABLE IF EXISTS `product_detail_building`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_building` (
  `PRODUCT_DETAIL_BUILDING_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio materiale edile',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto edile a cui appartiene questo dettaglio',
  `MATERIAL_TYPE` varchar(100) DEFAULT NULL COMMENT 'Tipo di materiale (es. Cemento, Laterizio, Acciaio, Legno, PVC)',
  `FIRE_RESISTANCE_CLASS` varchar(20) DEFAULT NULL COMMENT 'Classe di resistenza al fuoco secondo normativa europea (es. A1, B, C)',
  `THERMAL_CONDUCTIVITY` decimal(8,4) DEFAULT NULL COMMENT 'Coefficiente di conducibilita termica lambda in W/mK',
  `COMPRESSIVE_STRENGTH` decimal(10,2) DEFAULT NULL COMMENT 'Resistenza a compressione in N/mm2 o MPa',
  `LOAD_CAPACITY` decimal(10,2) DEFAULT NULL COMMENT 'Portata o carico massimo supportato in kg',
  `CE_MARKING` varchar(50) DEFAULT NULL COMMENT 'Numero o riferimento marcatura CE del prodotto',
  `IS_RECYCLABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e riciclabile a fine vita',
  `IS_CERTIFIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto dispone di certificazione tecnica o di qualita',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_BUILDING_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_BUILDING_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_BUILDING_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_BUILDING_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_BUILDING_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_BUILDING_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_BUILDING_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio materiali edili e ferramenta - caratteristiche tecniche e certificazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_building`
--

LOCK TABLES `product_detail_building` WRITE;
/*!40000 ALTER TABLE `product_detail_building` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_building` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_clothing`
--

DROP TABLE IF EXISTS `product_detail_clothing`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_clothing` (
  `PRODUCT_DETAIL_CLOTHING_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio abbigliamento',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto abbigliamento a cui appartiene questo dettaglio',
  `SIZE_SYSTEM` enum('EU','UK','US','IT','INT','OTHER') DEFAULT NULL COMMENT 'Sistema di taglia utilizzato: EU=europeo, UK=britannico, US=americano, IT=italiano, INT=internazionale XS-XXL, OTHER=altro',
  `SIZE_VALUE` varchar(20) DEFAULT NULL COMMENT 'Valore della taglia nel sistema indicato (es. 42, M, 10)',
  `GENDER` enum('MALE','FEMALE','UNISEX','KIDS','BABY') DEFAULT NULL COMMENT 'Genere di destinazione: MALE=uomo, FEMALE=donna, UNISEX=unisex, KIDS=bambino, BABY=neonato',
  `FABRIC_COMPOSITION` varchar(255) DEFAULT NULL COMMENT 'Composizione tessile percentuale (es. 100% Cotone, 80% Lana 20% Poliammide)',
  `COLOR_NAME` varchar(50) DEFAULT NULL COMMENT 'Nome commerciale del colore del prodotto',
  `COLOR_HEX` char(7) DEFAULT NULL COMMENT 'Codice colore esadecimale per visualizzazione interfaccia (es. #FF5733)',
  `SEASON` enum('SPRING_SUMMER','AUTUMN_WINTER','ALL_SEASON') DEFAULT NULL COMMENT 'Stagione di riferimento: SPRING_SUMMER=primavera-estate, AUTUMN_WINTER=autunno-inverno, ALL_SEASON=tutto l anno',
  `WASHING_INSTRUCTIONS` varchar(255) DEFAULT NULL COMMENT 'Istruzioni di lavaggio e manutenzione del capo',
  `IS_MADE_IN_ITALY` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato Made in Italy',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_CLOTHING_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_CLOTHING_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_CLOTHING_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_CLOTHING_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_CLOTHING_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_CLOTHING_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_CLOTHING_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti abbigliamento e tessile - taglia, colore, composizione e stagione';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_clothing`
--

LOCK TABLES `product_detail_clothing` WRITE;
/*!40000 ALTER TABLE `product_detail_clothing` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_clothing` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_electronics`
--

DROP TABLE IF EXISTS `product_detail_electronics`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_electronics` (
  `PRODUCT_DETAIL_ELECTRONICS_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio elettronico',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto elettronico a cui appartiene questo dettaglio',
  `BRAND` varchar(100) DEFAULT NULL COMMENT 'Marca o produttore del prodotto elettronico',
  `MODEL_NUMBER` varchar(100) DEFAULT NULL COMMENT 'Numero di modello o codice produttore',
  `POWER_CONSUMPTION` decimal(10,2) DEFAULT NULL COMMENT 'Consumo energetico in Watt',
  `VOLTAGE` varchar(20) DEFAULT NULL COMMENT 'Tensione di alimentazione (es. 220V, 12V, 5V)',
  `FREQUENCY` varchar(20) DEFAULT NULL COMMENT 'Frequenza elettrica (es. 50Hz, 60Hz)',
  `WARRANTY_MONTHS` int(10) unsigned DEFAULT NULL COMMENT 'Durata della garanzia in mesi',
  `ENERGY_CLASS` varchar(5) DEFAULT NULL COMMENT 'Classe di efficienza energetica (es. A+++, A+, B)',
  `CE_MARKING` varchar(50) DEFAULT NULL COMMENT 'Numero o riferimento marcatura CE del prodotto',
  `IS_WEEE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e soggetto alla direttiva RAEE smaltimento apparecchiature elettriche',
  `IS_REFURBISHED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e ricondizionato',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_ELECTRONICS_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_ELECTRONICS_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_ELECTRONICS_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_ELECTRONICS_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_ELECTRONICS_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_ELECTRONICS_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_ELECTRONICS_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti elettronica e informatica - specifiche tecniche, garanzia e conformita';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_electronics`
--

LOCK TABLES `product_detail_electronics` WRITE;
/*!40000 ALTER TABLE `product_detail_electronics` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_electronics` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_food`
--

DROP TABLE IF EXISTS `product_detail_food`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_food` (
  `PRODUCT_DETAIL_FOOD_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio alimentare',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto alimentare a cui appartiene questo dettaglio',
  `INGREDIENTS` text DEFAULT NULL COMMENT 'Lista ingredienti come richiesto dalla normativa etichettatura alimentare',
  `ALLERGENS` varchar(500) DEFAULT NULL COMMENT 'Allergeni presenti o possibili tracce secondo regolamento UE 1169/2011',
  `NUTRITIONAL_VALUES` text DEFAULT NULL COMMENT 'Valori nutrizionali per 100g o 100ml in formato testo o JSON',
  `STORAGE_CONDITIONS` varchar(255) DEFAULT NULL COMMENT 'Condizioni di conservazione raccomandate (es. conservare in luogo fresco e asciutto)',
  `STORAGE_TEMP_MIN` decimal(5,2) DEFAULT NULL COMMENT 'Temperatura minima di conservazione in gradi Celsius',
  `STORAGE_TEMP_MAX` decimal(5,2) DEFAULT NULL COMMENT 'Temperatura massima di conservazione in gradi Celsius',
  `SHELF_LIFE_DAYS` int(10) unsigned DEFAULT NULL COMMENT 'Durata media di conservazione in giorni dalla produzione',
  `IS_BIO` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato biologico',
  `IS_GLUTEN_FREE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato senza glutine',
  `IS_VEGAN` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e adatto a dieta vegana',
  `IS_VEGETARIAN` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e adatto a dieta vegetariana',
  `IS_FROZEN` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e surgelato o congelato',
  `ALCOHOL_PERCENT` decimal(5,2) DEFAULT NULL COMMENT 'Percentuale di alcol per bevande alcoliche - NULL se non applicabile',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_FOOD_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_FOOD_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_FOOD_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_FOOD_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_FOOD_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_FOOD_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_FOOD_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti alimentari e bevande - attributi nutrizionali, allergeni e conservazione';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_food`
--

LOCK TABLES `product_detail_food` WRITE;
/*!40000 ALTER TABLE `product_detail_food` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_food` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_furniture`
--

DROP TABLE IF EXISTS `product_detail_furniture`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_furniture` (
  `PRODUCT_DETAIL_FURNITURE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio arredamento',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto arredamento a cui appartiene questo dettaglio',
  `MATERIAL` varchar(100) DEFAULT NULL COMMENT 'Materiale principale del prodotto (es. Rovere massiccio, MDF laccato, Acciaio inox)',
  `FINISH` varchar(100) DEFAULT NULL COMMENT 'Finitura superficiale (es. Laccato opaco, Impiallacciato, Satinato)',
  `COLOR_NAME` varchar(50) DEFAULT NULL COMMENT 'Nome commerciale del colore o finitura',
  `COLOR_HEX` char(7) DEFAULT NULL COMMENT 'Codice colore esadecimale per visualizzazione interfaccia (es. #8B4513)',
  `ASSEMBLY_REQUIRED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto richiede montaggio da parte del cliente',
  `ASSEMBLY_TIME_MINUTES` int(10) unsigned DEFAULT NULL COMMENT 'Tempo stimato di montaggio in minuti',
  `IS_OUTDOOR` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e adatto per uso esterno',
  `IS_MADE_IN_ITALY` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e certificato Made in Italy',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_FURNITURE_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_FURNITURE_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_FURNITURE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_FURNITURE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_FURNITURE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_FURNITURE_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_FURNITURE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti arredamento e casalinghi - materiale, finitura, colore e montaggio';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_furniture`
--

LOCK TABLES `product_detail_furniture` WRITE;
/*!40000 ALTER TABLE `product_detail_furniture` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_furniture` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_jewelry`
--

DROP TABLE IF EXISTS `product_detail_jewelry`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_jewelry` (
  `PRODUCT_DETAIL_JEWELRY_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio orafo',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto orafo a cui appartiene questo dettaglio',
  `METAL_TYPE` enum('GOLD','SILVER','PLATINUM','PALLADIUM','BRONZE','STEEL','OTHER') DEFAULT NULL COMMENT 'Tipo di metallo principale: GOLD=oro, SILVER=argento, PLATINUM=platino, PALLADIUM=palladio, BRONZE=bronzo, STEEL=acciaio, OTHER=altro',
  `METAL_PURITY` varchar(10) DEFAULT NULL COMMENT 'Titolo o purezza del metallo (es. 750 per oro 18kt, 925 per argento sterling)',
  `GEMSTONE_TYPE` varchar(100) DEFAULT NULL COMMENT 'Tipo di pietra preziosa o semipreziosa principale (es. Diamante, Rubino, Smeraldo)',
  `GEMSTONE_CARAT` decimal(8,4) DEFAULT NULL COMMENT 'Peso in carati della pietra preziosa principale',
  `GEMSTONE_COLOR` varchar(50) DEFAULT NULL COMMENT 'Colore della pietra preziosa secondo classificazione GIA',
  `GEMSTONE_CLARITY` varchar(20) DEFAULT NULL COMMENT 'Purezza della pietra preziosa secondo classificazione GIA (es. VS1, SI2)',
  `HALLMARK_CODE` varchar(50) DEFAULT NULL COMMENT 'Codice punzone o marchio di garanzia',
  `CERTIFICATE_NUMBER` varchar(100) DEFAULT NULL COMMENT 'Numero certificato gemmologico (es. GIA, IGI)',
  `COLLECTION_NAME` varchar(100) DEFAULT NULL COMMENT 'Nome della collezione di appartenenza del gioiello',
  `IS_HANDCRAFTED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e realizzato artigianalmente',
  `IS_CERTIFIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto dispone di certificazione gemmologica',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_JEWELRY_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_JEWELRY_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_JEWELRY_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_JEWELRY_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_JEWELRY_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_JEWELRY_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_JEWELRY_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti orafi e gioielleria - metallo, pietre preziose e certificazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_jewelry`
--

LOCK TABLES `product_detail_jewelry` WRITE;
/*!40000 ALTER TABLE `product_detail_jewelry` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_jewelry` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_pharma`
--

DROP TABLE IF EXISTS `product_detail_pharma`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_pharma` (
  `PRODUCT_DETAIL_PHARMA_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio farmaceutico',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto farmaceutico a cui appartiene questo dettaglio',
  `AIC_CODE` varchar(20) DEFAULT NULL COMMENT 'Codice AIC - Autorizzazione Immissione in Commercio AIFA',
  `ATC_CODE` varchar(10) DEFAULT NULL COMMENT 'Codice ATC - classificazione anatomico terapeutica chimica WHO',
  `ACTIVE_INGREDIENT` varchar(255) DEFAULT NULL COMMENT 'Principio attivo o sostanza attiva principale del prodotto',
  `DOSAGE` varchar(100) DEFAULT NULL COMMENT 'Dosaggio o concentrazione del principio attivo (es. 500mg, 5mg/ml)',
  `PHARMACEUTICAL_FORM` varchar(100) DEFAULT NULL COMMENT 'Forma farmaceutica (es. Compressa, Capsula, Sciroppo, Crema)',
  `PRESCRIPTION_TYPE` enum('OTC','SOP','RR','RNR','OSP') DEFAULT NULL COMMENT 'Tipo ricetta: OTC=senza obbligo, SOP=senza ricetta con obbligo consiglio, RR=ricetta ripetibile, RNR=non ripetibile, OSP=ospedaliera',
  `SSN_CODE` varchar(20) DEFAULT NULL COMMENT 'Codice SSN per rimborso Sistema Sanitario Nazionale',
  `IS_REIMBURSABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e rimborsabile dal SSN',
  `IS_CONTROLLED_SUBSTANCE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e soggetto a normativa stupefacenti',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_PHARMA_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_PHARMA_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_PHARMA_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_PHARMA_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_PHARMA_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_PHARMA_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_PHARMA_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti farmaceutici e parafarmaceutici - codici AIFA, ATC, ricettazione e SSN';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_pharma`
--

LOCK TABLES `product_detail_pharma` WRITE;
/*!40000 ALTER TABLE `product_detail_pharma` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_pharma` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_detail_printing`
--

DROP TABLE IF EXISTS `product_detail_printing`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_detail_printing` (
  `PRODUCT_DETAIL_PRINTING_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del dettaglio tipografico',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto tipografico a cui appartiene questo dettaglio',
  `PAPER_FORMAT` varchar(20) DEFAULT NULL COMMENT 'Formato carta (es. A4, A3, A5, SRA3, 70x100)',
  `PAPER_WEIGHT` int(10) unsigned DEFAULT NULL COMMENT 'Grammatura della carta in g/m2 (es. 80, 130, 300)',
  `PRINT_COLORS` enum('BW','CMYK','PANTONE','CMYK_PANTONE') DEFAULT NULL COMMENT 'Tipo di stampa: BW=bianco e nero, CMYK=quadricromia, PANTONE=tinte piatte, CMYK_PANTONE=misto',
  `FINISHING` varchar(255) DEFAULT NULL COMMENT 'Lavorazioni di finitura (es. Plastificazione lucida, Verniciatura UV, Rilegatuta spirale)',
  `MIN_QUANTITY` int(10) unsigned DEFAULT NULL COMMENT 'Quantita minima ordinabile per prodotti tipografici personalizzati',
  `IS_CUSTOMIZABLE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto e personalizzabile con grafica del cliente',
  `IS_ECO_CERTIFIED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il prodotto ha certificazione ambientale FSC o PEFC',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_DETAIL_PRINTING_ID`),
  UNIQUE KEY `UQ_PROD_DETAIL_PRINTING_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PROD_DETAIL_PRINTING_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PROD_DETAIL_PRINTING_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PROD_DETAIL_PRINTING_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PROD_DETAIL_PRINTING_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PROD_DETAIL_PRINTING_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Dettaglio prodotti tipografia e cancelleria - formato, grammatura, stampa e finiture';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_detail_printing`
--

LOCK TABLES `product_detail_printing` WRITE;
/*!40000 ALTER TABLE `product_detail_printing` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_detail_printing` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_price`
--

DROP TABLE IF EXISTS `product_price`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_price` (
  `PRODUCT_PRICE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del prezzo prodotto nel listino',
  `PRICE_LIST_ID` int(10) unsigned NOT NULL COMMENT 'FK verso price_list - listino a cui appartiene questo prezzo',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto a cui si applica questo prezzo',
  `PRICE` decimal(15,5) NOT NULL COMMENT 'Prezzo unitario del prodotto in questo listino nella valuta del listino',
  `DISCOUNT_PERCENT` decimal(5,2) NOT NULL DEFAULT 0.00 COMMENT 'Sconto percentuale aggiuntivo applicato a questo prodotto in questo listino',
  `MIN_QUANTITY` decimal(15,5) NOT NULL DEFAULT 1.00000 COMMENT 'Quantita minima per applicare questo prezzo - utile per prezzi a scaglioni',
  `VALID_FROM` date DEFAULT NULL COMMENT 'Data di inizio validita del prezzo - sovrascrive la validita del listino se valorizzata',
  `VALID_TO` date DEFAULT NULL COMMENT 'Data di fine validita del prezzo - sovrascrive la validita del listino se valorizzata',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_PRICE_ID`),
  UNIQUE KEY `UQ_PRODUCT_PRICE_LIST_PRODUCT_QTY` (`PRICE_LIST_ID`,`PRODUCT_ID`,`MIN_QUANTITY`),
  KEY `IDX_PRODUCT_PRICE_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PRODUCT_PRICE_VALID_FROM` (`VALID_FROM`),
  KEY `IDX_PRODUCT_PRICE_VALID_TO` (`VALID_TO`),
  KEY `IDX_PRODUCT_PRICE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PRODUCT_PRICE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PRODUCT_PRICE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PRODUCT_PRICE_PRICE_LIST_ID` FOREIGN KEY (`PRICE_LIST_ID`) REFERENCES `price_list` (`PRICE_LIST_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PRODUCT_PRICE_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PRODUCT_PRICE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Prezzi prodotto per listino - supporta prezzi a scaglioni tramite MIN_QUANTITY e validita temporale per prodotto';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_price`
--

LOCK TABLES `product_price` WRITE;
/*!40000 ALTER TABLE `product_price` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_price` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `product_price_override`
--

DROP TABLE IF EXISTS `product_price_override`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product_price_override` (
  `PRODUCT_PRICE_OVERRIDE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del prezzo personalizzato cliente',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente proprietario di questa eccezione prezzo',
  `CUSTOMER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso customer - cliente a cui si applica questo prezzo personalizzato',
  `PRODUCT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso product - prodotto per cui si applica questo prezzo personalizzato',
  `PRICE` decimal(15,5) DEFAULT NULL COMMENT 'Prezzo fisso personalizzato - se valorizzato ha priorita sul prezzo del listino',
  `DISCOUNT_PERCENT` decimal(5,2) DEFAULT NULL COMMENT 'Sconto percentuale personalizzato - applicato al prezzo del listino assegnato al cliente',
  `VALID_FROM` date DEFAULT NULL COMMENT 'Data di inizio validita del prezzo personalizzato',
  `VALID_TO` date DEFAULT NULL COMMENT 'Data di fine validita del prezzo personalizzato',
  `NOTE` varchar(255) DEFAULT NULL COMMENT 'Nota o motivazione del prezzo personalizzato (es. accordo commerciale, promozione)',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha creato il record',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`PRODUCT_PRICE_OVERRIDE_ID`),
  UNIQUE KEY `UQ_PRICE_OVERRIDE_CUSTOMER_PRODUCT` (`CUSTOMER_ID`,`PRODUCT_ID`),
  KEY `IDX_PRICE_OVERRIDE_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_PRICE_OVERRIDE_PRODUCT_ID` (`PRODUCT_ID`),
  KEY `IDX_PRICE_OVERRIDE_VALID_FROM` (`VALID_FROM`),
  KEY `IDX_PRICE_OVERRIDE_VALID_TO` (`VALID_TO`),
  KEY `IDX_PRICE_OVERRIDE_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_PRICE_OVERRIDE_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_PRICE_OVERRIDE_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_PRICE_OVERRIDE_CUSTOMER_ID` FOREIGN KEY (`CUSTOMER_ID`) REFERENCES `customer` (`CUSTOMER_ID`),
  CONSTRAINT `FK_PRICE_OVERRIDE_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`),
  CONSTRAINT `FK_PRICE_OVERRIDE_PRODUCT_ID` FOREIGN KEY (`PRODUCT_ID`) REFERENCES `product` (`PRODUCT_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_PRICE_OVERRIDE_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Prezzi personalizzati per cliente e prodotto - massima priorita nella risoluzione prezzi sopra qualsiasi listino';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `product_price_override`
--

LOCK TABLES `product_price_override` WRITE;
/*!40000 ALTER TABLE `product_price_override` DISABLE KEYS */;
/*!40000 ALTER TABLE `product_price_override` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `province`
--

DROP TABLE IF EXISTS `province`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `province` (
  `PROVINCE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della provincia',
  `REGION_ID` int(10) unsigned NOT NULL COMMENT 'FK verso region - regione di appartenenza della provincia',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome completo della provincia (es. Milano, Roma)',
  `CODE` varchar(2) NOT NULL COMMENT 'Sigla della provincia (es. MI, RM)',
  `ISTAT_CODE` varchar(4) NOT NULL COMMENT 'Codice ISTAT della provincia',
  `CAP_PREFIX` varchar(40) DEFAULT NULL COMMENT 'Prefisso o prefissi CAP della provincia',
  `IS_CAP_FORCED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se il CAP deve corrispondere esattamente al prefisso',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`PROVINCE_ID`),
  UNIQUE KEY `UQ_PROVINCE_CODE` (`CODE`),
  UNIQUE KEY `UQ_PROVINCE_ISTAT_CODE` (`ISTAT_CODE`),
  KEY `IDX_PROVINCE_REGION_ID` (`REGION_ID`),
  CONSTRAINT `FK_PROVINCE_REGION_ID` FOREIGN KEY (`REGION_ID`) REFERENCES `region` (`REGION_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica province italiane ed equivalenti per altre nazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `province`
--

LOCK TABLES `province` WRITE;
/*!40000 ALTER TABLE `province` DISABLE KEYS */;
/*!40000 ALTER TABLE `province` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `region`
--

DROP TABLE IF EXISTS `region`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `region` (
  `REGION_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco della regione',
  `NATION_ID` int(10) unsigned NOT NULL COMMENT 'FK verso nation - nazione di appartenenza della regione',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Nome della regione (es. Lombardia, Veneto)',
  `ISTAT_CODE` varchar(4) NOT NULL COMMENT 'Codice ISTAT della regione (es. 03, 05)',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`REGION_ID`),
  UNIQUE KEY `UQ_REGION_ISTAT_CODE` (`ISTAT_CODE`),
  KEY `IDX_REGION_NATION_ID` (`NATION_ID`),
  CONSTRAINT `FK_REGION_NATION_ID` FOREIGN KEY (`NATION_ID`) REFERENCES `nation` (`NATION_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica regioni italiane ed equivalenti per altre nazioni';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `region`
--

LOCK TABLES `region` WRITE;
/*!40000 ALTER TABLE `region` DISABLE KEYS */;
/*!40000 ALTER TABLE `region` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `subject_type`
--

DROP TABLE IF EXISTS `subject_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `subject_type` (
  `SUBJECT_TYPE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tipo soggetto',
  `CODE` varchar(5) NOT NULL COMMENT 'Codice breve (es. PF=Persona Fisica, PG=Persona Giuridica)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione del tipo soggetto',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  PRIMARY KEY (`SUBJECT_TYPE_ID`),
  UNIQUE KEY `UQ_SUBJECT_TYPE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tipi soggetto - persona fisica vs persona giuridica (Tipo soggetto)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `subject_type`
--

LOCK TABLES `subject_type` WRITE;
/*!40000 ALTER TABLE `subject_type` DISABLE KEYS */;
/*!40000 ALTER TABLE `subject_type` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `tax_rate`
--

DROP TABLE IF EXISTS `tax_rate`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `tax_rate` (
  `TAX_RATE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco dell aliquota o natura IVA',
  `ISSUER_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso issuer - NULL indica aliquota di sistema, valorizzato indica aliquota personalizzata del cedente',
  `CODE` varchar(40) NOT NULL COMMENT 'Codice breve es. IVA22, IVA10, N2.1, N4',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione leggibile dell aliquota o natura',
  `TAX_TYPE` enum('T','E') NOT NULL DEFAULT 'T' COMMENT 'T=Aliquota IVA imponibile, E=Natura esenzione',
  `RATE` decimal(5,2) DEFAULT NULL COMMENT 'Percentuale IVA es. 22.00, 10.00 - NULL quando TAX_TYPE=E',
  `NATURA_CODE` char(6) DEFAULT NULL COMMENT 'Codice natura SDI es. N2.1, N4, N6.1 - NULL quando TAX_TYPE=T',
  `ASSOSOFTWARE_CODE` varchar(7) DEFAULT NULL COMMENT 'Codice raccordo Assosoftware o SDI per riconciliazione contabile',
  `IS_BOLLO` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questa natura richiede il calcolo del bollo virtuale',
  `IS_MINISTERIALE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se codice ministeriale standard, 0 se personalizzato dal cedente',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 obsoleta non piu utilizzabile',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`TAX_RATE_ID`),
  UNIQUE KEY `UQ_TAX_RATE_CODE_ISSUER` (`CODE`,`ISSUER_ID`),
  KEY `IDX_TAX_RATE_TYPE` (`TAX_TYPE`),
  KEY `IDX_TAX_RATE_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_TAX_RATE_IS_ACTIVE` (`IS_ACTIVE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tabella unificata aliquote IVA (T) e nature di esenzione (E) - sia di sistema che personalizzate per cedente';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `tax_rate`
--

LOCK TABLES `tax_rate` WRITE;
/*!40000 ALTER TABLE `tax_rate` DISABLE KEYS */;
/*!40000 ALTER TABLE `tax_rate` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `tenant`
--

DROP TABLE IF EXISTS `tenant`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `tenant` (
  `TENANT_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tenant',
  `COMPANY_NAME` varchar(255) NOT NULL COMMENT 'Ragione sociale dell azienda che utilizza il sistema',
  `VAT_NUMBER` varchar(20) DEFAULT NULL COMMENT 'Partita IVA italiana del tenant',
  `SUBSCRIPTION_PLAN` enum('starter','professional','enterprise') DEFAULT NULL COMMENT 'Piano di abbonamento attivo: starter, professional, enterprise',
  `STATUS` enum('trial','active','suspended') DEFAULT 'trial' COMMENT 'Stato dell account: trial=prova, active=attivo, suspended=sospeso',
  `CREATED_AT` timestamp NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_AT` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`TENANT_ID`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica tenant - aziende o studi che utilizzano la piattaforma';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `tenant`
--

LOCK TABLES `tenant` WRITE;
/*!40000 ALTER TABLE `tenant` DISABLE KEYS */;
INSERT INTO `tenant` VALUES (1,'Alimentari Rossi SRL','IT12345678901','professional','active','2026-03-08 19:30:53','2026-03-08 19:30:53'),(2,'Supermercato Bianchi SPA','IT98765432109','enterprise','active','2026-03-08 19:30:53','2026-03-08 19:30:53');
/*!40000 ALTER TABLE `tenant` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `tenant_setting`
--

DROP TABLE IF EXISTS `tenant_setting`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `tenant_setting` (
  `TENANT_SETTING_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco delle impostazioni tenant',
  `TENANT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso tenant - tenant a cui appartengono le impostazioni',
  `WHATSAPP_BUSINESS_PHONE` varchar(20) DEFAULT NULL COMMENT 'Numero di telefono WhatsApp Business del tenant',
  `WHATSAPP_API_KEY` varchar(255) DEFAULT NULL COMMENT 'Chiave API per l integrazione WhatsApp',
  `IS_WHATSAPP_ENABLED` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se le notifiche WhatsApp sono abilitate',
  `IS_NOTIFY_NEW_ORDERS` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se inviare notifiche per nuovi ordini',
  `IS_NOTIFY_LOW_STOCK` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se inviare avvisi di scorta minima',
  `DEFAULT_TAX_RATE_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tax_rate - aliquota IVA predefinita del tenant (usata come fallback quando il prodotto non ha aliquota)',
  `SDI_CODE` varchar(7) DEFAULT NULL COMMENT 'Codice destinatario SDI del tenant',
  `PEC_EMAIL` varchar(255) DEFAULT NULL COMMENT 'Indirizzo PEC del tenant per ricezione fatture elettroniche',
  PRIMARY KEY (`TENANT_SETTING_ID`),
  UNIQUE KEY `UQ_TENANT_SETTING_TENANT_ID` (`TENANT_ID`),
  KEY `IDX_TENANT_SETTING_TAX_RATE_ID` (`DEFAULT_TAX_RATE_ID`),
  CONSTRAINT `FK_TENANT_SETTING_TAX_RATE_ID` FOREIGN KEY (`DEFAULT_TAX_RATE_ID`) REFERENCES `tax_rate` (`TAX_RATE_ID`) ON DELETE NO ACTION ON UPDATE NO ACTION,
  CONSTRAINT `FK_TENANT_SETTING_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Impostazioni operative e di integrazione per ogni tenant';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `tenant_setting`
--

LOCK TABLES `tenant_setting` WRITE;
/*!40000 ALTER TABLE `tenant_setting` DISABLE KEYS */;
INSERT INTO `tenant_setting` VALUES (1,1,NULL,NULL,0,1,1,NULL,NULL,NULL),(2,2,NULL,NULL,0,1,1,NULL,NULL,NULL);
/*!40000 ALTER TABLE `tenant_setting` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `unit_of_measure`
--

DROP TABLE IF EXISTS `unit_of_measure`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `unit_of_measure` (
  `UNIT_OF_MEASURE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco dell unita di misura',
  `CODE` varchar(20) NOT NULL COMMENT 'Codice breve dell unita di misura (es. KG, LT, PZ, MT)',
  `SYMBOL` varchar(10) NOT NULL COMMENT 'Simbolo visualizzato nei documenti e nell interfaccia (es. kg, lt, pz, m)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione completa dell unita di misura (es. Chilogrammo, Litro)',
  `MEASURE_TYPE` enum('WEIGHT','LENGTH','VOLUME','QUANTITY','AREA','TIME') NOT NULL COMMENT 'Categoria dell unita: WEIGHT=peso, LENGTH=lunghezza, VOLUME=volume, QUANTITY=quantita generica, AREA=superficie, TIME=tempo',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`UNIT_OF_MEASURE_ID`),
  UNIQUE KEY `UQ_UNIT_OF_MEASURE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Unita di misura per prodotti e movimenti di magazzino - base e vendita';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `unit_of_measure`
--

LOCK TABLES `unit_of_measure` WRITE;
/*!40000 ALTER TABLE `unit_of_measure` DISABLE KEYS */;
/*!40000 ALTER TABLE `unit_of_measure` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `user`
--

DROP TABLE IF EXISTS `user`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user` (
  `USER_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco dell utente',
  `TENANT_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tenant - azienda principale di appartenenza dell utente',
  `EMAIL` varchar(255) NOT NULL COMMENT 'Indirizzo email dell utente - utilizzato per il login',
  `PASSWORD` varchar(255) NOT NULL COMMENT 'Password cifrata con bcrypt o argon2',
  `PHONE` varchar(20) NOT NULL COMMENT 'Numero di telefono con prefisso internazionale',
  `NAME` varchar(100) NOT NULL COMMENT 'Nome dell utente',
  `SURNAME` varchar(100) NOT NULL COMMENT 'Cognome dell utente',
  `FULL_NAME` varchar(255) GENERATED ALWAYS AS (concat_ws(' ',`NAME`,`SURNAME`)) STORED COMMENT 'Nome completo generato automaticamente dalla concatenazione di nome e cognome',
  `USER_TYPE` enum('ADMIN','OPERATOR','DRIVER','CUSTOMER') NOT NULL DEFAULT 'CUSTOMER' COMMENT 'Ruolo dell utente nel sistema: ADMIN=amministratore, OPERATOR=operatore, DRIVER=autista, CUSTOMER=cliente',
  `IS_ACTIVE` tinyint(1) unsigned DEFAULT 1 COMMENT '0=disabilitato, 1=attivo',
  `IS_VERIFIED` tinyint(1) unsigned DEFAULT 0 COMMENT '0=non verificato, 1=email o telefono verificati',
  `IS_ONLINE` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT 'Stato di connessione corrente - usato per autisti e operatori',
  `FAILED_LOGIN_ATTEMPTS` int(10) unsigned DEFAULT 0 COMMENT 'Contatore tentativi di login falliti',
  `LOCKED_UNTIL` datetime DEFAULT NULL COMMENT 'Account bloccato fino a questa data e ora dopo troppi tentativi falliti',
  `LAST_LOGIN_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo login riuscito',
  `LAST_LOGIN_IP` varchar(45) DEFAULT NULL COMMENT 'Indirizzo IP dell ultimo login (IPv4 o IPv6)',
  `PASSWORD_CHANGED_AT` datetime DEFAULT NULL COMMENT 'Data e ora dell ultimo cambio password',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione dell account',
  `UPDATED_AT` datetime DEFAULT NULL ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`USER_ID`),
  UNIQUE KEY `UQ_USER_EMAIL` (`EMAIL`),
  KEY `IDX_USER_TYPE` (`USER_TYPE`),
  KEY `IDX_USER_TENANT_ID` (`TENANT_ID`),
  CONSTRAINT `FK_USER_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Anagrafica utenti - autenticazione e profilo base per accesso alla piattaforma';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `user`
--

LOCK TABLES `user` WRITE;
/*!40000 ALTER TABLE `user` DISABLE KEYS */;
INSERT INTO `user` (`USER_ID`, `TENANT_ID`, `EMAIL`, `PASSWORD`, `PHONE`, `NAME`, `SURNAME`, `USER_TYPE`, `IS_ACTIVE`, `IS_VERIFIED`, `IS_ONLINE`, `FAILED_LOGIN_ATTEMPTS`, `LOCKED_UNTIL`, `LAST_LOGIN_AT`, `LAST_LOGIN_IP`, `PASSWORD_CHANGED_AT`, `CREATED_AT`, `UPDATED_AT`) VALUES (5,NULL,'userdieci@gmail.com','nfDNrVR30lgwYSLF+PAj+JJ1wzu9OaamtyeYksrsWaPHJ1FXcPWfLZ5EXe+CFJDQ','+3912345678','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-13 23:15:58',NULL),(6,NULL,'mio@mio.com','PrEog/RYTyeGAidqP6MTGzQ+f08CjGpG5AN/PO1aiPAO9NBbWngXMnKL7U1gWP/w','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-17 17:31:47',NULL),(7,NULL,'mio2@mio.com','3oyYw4+LYltnm1jGRRgAlir9mdXjE29lsgOxQXr2Z0Yw1eBS0e+FPgONjRhkD8CN','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-17 17:54:54',NULL),(8,NULL,'mio3@mio.com','3X1l+4duvfxIO/OmZ+WVU4EydRaenIbXR4ii7Y6XC+pz/WiLRA56XNkwuZbCI+px','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-17 18:09:03',NULL),(9,NULL,'mio4@mio.com','76O41Xrr+Bm1VR/eA9QBCZA5ioQ0vBVrDoDZPIh1gagj0AR8mMTkGRzvOiF8SbeL','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-17 18:22:23',NULL),(10,NULL,'1mio@mio.com','fmZb/XoZkhVo4wOvlGA44IfJVDweye7YjNaRjvLdlCldXCHo+HNZSTXh3ifiBcwl','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-19 10:42:38',NULL),(11,NULL,'2mio@mio.com','m6P4MMlYucSam/tDy503PS6stCgKDUokDH+sPywFys2iJHzOkhljYwcE59bj6DgI','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-19 10:44:32',NULL),(12,NULL,'3mio@mio.com','F3WiMZu9ELFnag+UYYOVXv6t2v4G7FjVTeE6mYZJI67hUcuzLLbcgbXtBNeZWiE2','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-19 10:44:43',NULL),(13,NULL,'4mio@mio.com','STNHPFFSqysez22wBIn5Lk+7FWUl7kb1KeyHsRm43pQr4WtRJPqoWBbDEuR0pbW5','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-19 17:25:38',NULL),(14,NULL,'7mio@mio.com','Qr+uqxteM+/h5kemFGCnEKisf0uyAZMC+8sFMk4zPLqhBLg2vC9cU/i3puaBfNWs','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-26 17:33:58',NULL),(15,NULL,'11mio@mio.com','ju8d2QPDzobxeAO4CLuw4u2VN+06hooKgQB4pIq60KAX3tJko/ZEnJQqChdiduPD','+39','Pinko','Pallino','OPERATOR',1,0,0,0,NULL,NULL,NULL,NULL,'2026-03-30 17:58:56',NULL);
/*!40000 ALTER TABLE `user` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `user_issuer`
--

DROP TABLE IF EXISTS `user_issuer`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_issuer` (
  `USER_ISSUER_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record di accesso cedente',
  `USER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha accesso al cedente',
  `ISSUER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso issuer - cedente a cui l utente ha accesso',
  `ROLE` enum('OWNER','ADMIN','OPERATOR','READONLY') NOT NULL DEFAULT 'OPERATOR' COMMENT 'Ruolo dell utente per questo cedente: OWNER=proprietario, ADMIN=amministratore, OPERATOR=operatore standard, READONLY=sola lettura',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se questo accesso e attualmente attivo',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha concesso l accesso',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`USER_ISSUER_ID`),
  UNIQUE KEY `UQ_USER_ISSUER_USER_ISSUER` (`USER_ID`,`ISSUER_ID`),
  KEY `IDX_USER_ISSUER_ISSUER_ID` (`ISSUER_ID`),
  KEY `IDX_USER_ISSUER_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_USER_ISSUER_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_USER_ISSUER_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_USER_ISSUER_ISSUER_ID` FOREIGN KEY (`ISSUER_ID`) REFERENCES `issuer` (`ISSUER_ID`) ON DELETE CASCADE,
  CONSTRAINT `FK_USER_ISSUER_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_USER_ISSUER_USER_ID` FOREIGN KEY (`USER_ID`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tabella di giunzione utente-cedente con ruolo - un utente puo gestire piu cedenti con ruoli diversi';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `user_issuer`
--

LOCK TABLES `user_issuer` WRITE;
/*!40000 ALTER TABLE `user_issuer` DISABLE KEYS */;
/*!40000 ALTER TABLE `user_issuer` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `user_media`
--

DROP TABLE IF EXISTS `user_media`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_media` (
  `USER_MEDIA_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del file media',
  `USER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente proprietario del file',
  `TENANT_ID` int(10) unsigned DEFAULT NULL COMMENT 'FK verso tenant - tenant di appartenenza del file, NULL per media non legati a un tenant',
  `MEDIA_TYPE` enum('AVATAR','COMPANY_LOGO','INVOICE_BACKGROUND','DOCUMENT','XML_TEMPLATE') NOT NULL COMMENT 'Tipo di media: AVATAR=foto profilo, COMPANY_LOGO=logo aziendale, INVOICE_BACKGROUND=sfondo fattura, DOCUMENT=documento generico, XML_TEMPLATE=template XML',
  `FILE_NAME` varchar(255) NOT NULL COMMENT 'Nome originale del file caricato',
  `FILE_PATH` varchar(500) NOT NULL COMMENT 'Percorso di archiviazione del file sul server',
  `MIME_TYPE` varchar(100) NOT NULL COMMENT 'Tipo MIME del file (es. image/png, application/pdf)',
  `FILE_SIZE` int(11) DEFAULT NULL COMMENT 'Dimensione del file in byte',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di caricamento del file',
  `UPDATED_AT` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`USER_MEDIA_ID`),
  KEY `IDX_USER_MEDIA_USER_ID` (`USER_ID`),
  KEY `IDX_USER_MEDIA_TENANT_ID` (`TENANT_ID`),
  CONSTRAINT `FK_USER_MEDIA_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`) ON DELETE SET NULL,
  CONSTRAINT `FK_USER_MEDIA_USER_ID` FOREIGN KEY (`USER_ID`) REFERENCES `user` (`USER_ID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='File media degli utenti - avatar, loghi aziendali, sfondi fattura, documenti e template XML';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `user_media`
--

LOCK TABLES `user_media` WRITE;
/*!40000 ALTER TABLE `user_media` DISABLE KEYS */;
/*!40000 ALTER TABLE `user_media` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `user_tenant`
--

DROP TABLE IF EXISTS `user_tenant`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_tenant` (
  `USER_TENANT_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del record di accesso tenant',
  `USER_ID` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha accesso al tenant',
  `TENANT_ID` int(10) unsigned NOT NULL COMMENT 'FK verso tenant - tenant a cui l utente ha accesso',
  `ROLE` enum('OWNER','ADMIN','OPERATOR','READONLY') NOT NULL DEFAULT 'OPERATOR' COMMENT 'Ruolo dell utente nel tenant: OWNER=proprietario, ADMIN=amministratore, OPERATOR=operatore, READONLY=sola lettura',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 se questo accesso e attivo',
  `CREATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha concesso l accesso',
  `CREATED_AT` datetime NOT NULL DEFAULT current_timestamp() COMMENT 'Data e ora di creazione del record',
  `UPDATED_BY` int(10) unsigned NOT NULL COMMENT 'FK verso user - utente che ha effettuato l ultimo aggiornamento',
  `UPDATED_AT` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp() COMMENT 'Data e ora dell ultimo aggiornamento',
  PRIMARY KEY (`USER_TENANT_ID`),
  UNIQUE KEY `UQ_USER_TENANT_USER_TENANT` (`USER_ID`,`TENANT_ID`),
  KEY `IDX_USER_TENANT_TENANT_ID` (`TENANT_ID`),
  KEY `IDX_USER_TENANT_CREATED_BY` (`CREATED_BY`),
  KEY `IDX_USER_TENANT_UPDATED_BY` (`UPDATED_BY`),
  CONSTRAINT `FK_USER_TENANT_CREATED_BY` FOREIGN KEY (`CREATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_USER_TENANT_TENANT_ID` FOREIGN KEY (`TENANT_ID`) REFERENCES `tenant` (`TENANT_ID`),
  CONSTRAINT `FK_USER_TENANT_UPDATED_BY` FOREIGN KEY (`UPDATED_BY`) REFERENCES `user` (`USER_ID`),
  CONSTRAINT `FK_USER_TENANT_USER_ID` FOREIGN KEY (`USER_ID`) REFERENCES `user` (`USER_ID`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tabella di giunzione utente-tenant con ruolo - un utente puo appartenere a piu tenant con ruoli diversi';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `user_tenant`
--

LOCK TABLES `user_tenant` WRITE;
/*!40000 ALTER TABLE `user_tenant` DISABLE KEYS */;
/*!40000 ALTER TABLE `user_tenant` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `welfare_fund_type`
--

DROP TABLE IF EXISTS `welfare_fund_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `welfare_fund_type` (
  `WELFARE_FUND_TYPE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tipo cassa previdenziale',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice SDI della cassa previdenziale (es. TC01, TC02)',
  `DESCRIPTION` varchar(100) NOT NULL COMMENT 'Descrizione della cassa previdenziale',
  `XML_REFERENCE` varchar(100) NOT NULL COMMENT 'Riferimento da inserire nella sezione Altri Dati del XML fattura',
  `IS_FORFETTARI_INCOME` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT '1 se questa cassa genera reddito imponibile per i forfettari',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attiva, 0 disabilitata',
  PRIMARY KEY (`WELFARE_FUND_TYPE_ID`),
  UNIQUE KEY `UQ_WELFARE_FUND_TYPE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tipi cassa previdenziale e assistenziale usati nel XML fattura (Tipo cassa previdenziale)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `welfare_fund_type`
--

LOCK TABLES `welfare_fund_type` WRITE;
/*!40000 ALTER TABLE `welfare_fund_type` DISABLE KEYS */;
/*!40000 ALTER TABLE `welfare_fund_type` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `withholding_type`
--

DROP TABLE IF EXISTS `withholding_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `withholding_type` (
  `WITHHOLDING_TYPE_ID` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identificatore univoco del tipo ritenuta',
  `CODE` varchar(4) NOT NULL COMMENT 'Codice breve (es. RT01, RT02)',
  `DESCRIPTION` varchar(50) NOT NULL COMMENT 'Descrizione del tipo ritenuta',
  `CATEGORY` enum('WITHHOLDING','INPS','ENASARCO','ENPAM','OTHER') NOT NULL DEFAULT 'WITHHOLDING' COMMENT 'Categoria: WITHHOLDING=ritenuta d acconto, INPS/ENASARCO/ENPAM=contributi previdenziali, OTHER=altri contributi',
  `IS_ACTIVE` tinyint(1) unsigned NOT NULL DEFAULT 1 COMMENT '1 attivo, 0 disabilitato',
  PRIMARY KEY (`WITHHOLDING_TYPE_ID`),
  UNIQUE KEY `UQ_WITHHOLDING_TYPE_CODE` (`CODE`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Tipi ritenuta e contributi previdenziali (Tipo ritenuta)';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `withholding_type`
--

LOCK TABLES `withholding_type` WRITE;
/*!40000 ALTER TABLE `withholding_type` DISABLE KEYS */;
/*!40000 ALTER TABLE `withholding_type` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Dumping routines for database 'userdieci11_ims'
--
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-04-02 14:42:13
